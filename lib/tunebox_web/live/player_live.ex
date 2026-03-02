defmodule TuneboxWeb.PlayerLive do
  use TuneboxWeb, :live_view

  alias TuneBox.Config
  alias TuneBox.Music
  alias TuneBox.Music.{ArtworkFetcher, Importer}
  alias TuneBox.Player

  def mount(_params, _session, socket) do
    live_tracks = Music.list_live_tracks()
    tracks = Enum.map(live_tracks, & &1.track)
    track_map = Map.new(tracks, &{&1.id, &1})

    if connected?(socket), do: Phoenix.PubSub.subscribe(Tunebox.PubSub, "player:status")

    {restored_track, restored_time, restored_duration} =
      case Config.get_paused_state() do
        {track_id, time_pos, duration} ->
          case Map.get(track_map, track_id) do
            nil -> {nil, 0.0, 0.0}
            track -> {track, time_pos, duration}
          end

        nil ->
          {nil, 0.0, 0.0}
      end

    socket =
      socket
      |> stream(:tracks, tracks)
      |> assign(:track_list, tracks)
      |> assign(:track_map, track_map)
      |> assign(:selected_track, restored_track)
      |> assign(:playing_track, nil)
      |> assign(:playback_state, if(restored_track, do: :paused, else: :stopped))
      |> assign(:player_available, Process.whereis(TuneBox.Player) != nil)
      |> assign(:time_pos, restored_time)
      |> assign(:duration, restored_duration)
      |> assign(:importing, false)
      |> assign(:import_error, nil)
      |> assign(:import_current_folder, nil)
      |> assign(:total_tracks, Music.count_tracks())
      |> assign(:music_library_path, Config.music_library_path() || "")
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:show_settings, false)
      |> assign(:artists, [])
      |> assign(:editing_artist, nil)
      |> assign(:artist_form, to_form(Music.change_artist(%TuneBox.Music.Artist{})))
      |> assign(:editing_track, nil)
      |> assign(:track_form, nil)
      |> assign(:all_artists, [])
      |> assign(:all_albums, [])
      |> assign(:max_visible_tracks, Config.max_visible_tracks())
      |> assign(:remove_completed_tracks, Config.remove_completed_tracks?())

    {:ok, socket}
  end

  def handle_event("select_track", %{"id" => id}, socket) do
    track_id = String.to_integer(id)
    selected = socket.assigns.selected_track

    # Don't re-render if clicking inside the edit form of the already-selected track.
    if selected && selected.id == track_id && socket.assigns.editing_track do
      {:noreply, socket}
    else
      new_track = Map.get(socket.assigns.track_map, track_id)
      was_playing = socket.assigns.playback_state == :playing

      socket =
        socket
        |> assign(:selected_track, new_track)
        |> assign(:editing_track, nil)
        |> assign(:track_form, nil)
        |> stream(:tracks, socket.assigns.track_list, reset: true)

      socket =
        if was_playing and socket.assigns.player_available do
          Player.play(new_track.file_path)
          assign(socket, :playing_track, new_track)
        else
          socket
        end

      maybe_fetch_artwork(new_track)

      {:noreply, socket}
    end
  end

  def handle_event("prev_track", _params, socket) do
    {:noreply, select_adjacent_track(socket, -1)}
  end

  def handle_event("next_track", _params, socket) do
    {:noreply, select_adjacent_track(socket, 1)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    results = Music.search_tracks(query)
    {:noreply, socket |> assign(:search_query, query) |> assign(:search_results, results)}
  end

  def handle_event("add_to_live", %{"id" => id}, socket) do
    track_id = String.to_integer(id)
    Music.add_live_track(track_id)
    live_tracks = Music.list_live_tracks()

    {:noreply, reload_tracks(socket, live_tracks)}
  end

  def handle_event("import", %{"path" => path}, socket) do
    path = String.trim(path)

    cond do
      path == "" ->
        {:noreply, assign(socket, :import_error, "Please enter a folder path.")}

      not File.dir?(path) ->
        {:noreply, assign(socket, :import_error, "Folder doesn't exist.")}

      true ->
        Config.set_music_library_path(path)
        parent = self()

        Task.start(fn ->
          try do
            Importer.import(path, fn folder -> send(parent, {:import_progress, folder}) end)
            send(parent, :import_done)
          rescue
            e -> send(parent, {:import_error, Exception.message(e)})
          end
        end)

        {:noreply,
         socket
         |> assign(:importing, true)
         |> assign(:import_error, nil)
         |> assign(:music_library_path, path)}
    end
  end

  def handle_event(event, _params, %{assigns: %{player_available: false}} = socket)
      when event in ~w(play pause stop rewind fast_forward) do
    {:noreply,
     put_flash(socket, :error, "mpv is not installed. Install it with: sudo apt install mpv")}
  end

  def handle_event("play", _params, %{assigns: %{selected_track: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("play", _params, %{assigns: assigns} = socket) do
    same_track =
      assigns.playing_track != nil and assigns.playing_track.id == assigns.selected_track.id

    if assigns.playback_state == :paused and same_track do
      Player.resume()
    else
      # Resume from saved position if restoring a persisted paused state
      if assigns.time_pos > 0 and is_nil(assigns.playing_track) do
        Player.play_from(assigns.selected_track.file_path, assigns.time_pos)
      else
        Player.play(assigns.selected_track.file_path)
      end
    end

    Config.clear_paused_state()

    {:noreply,
     socket
     |> assign(:playback_state, :playing)
     |> assign(:playing_track, assigns.selected_track)
     |> stream(:tracks, socket.assigns.track_list, reset: true)}
  end

  def handle_event("pause", _params, socket) do
    Player.pause()

    if socket.assigns.playing_track do
      Config.set_paused_state(
        socket.assigns.playing_track.id,
        socket.assigns.time_pos,
        socket.assigns.duration
      )
    end

    {:noreply,
     socket
     |> assign(:playback_state, :paused)
     |> stream(:tracks, socket.assigns.track_list, reset: true)}
  end

  def handle_event("stop", _params, socket) do
    Player.stop()
    Config.clear_paused_state()

    {:noreply,
     socket
     |> assign(:playback_state, :stopped)
     |> assign(:playing_track, nil)
     |> assign(:time_pos, 0.0)
     |> stream(:tracks, socket.assigns.track_list, reset: true)}
  end

  def handle_event("rewind", _params, socket) do
    Player.rewind()
    {:noreply, socket}
  end

  def handle_event("fast_forward", _params, socket) do
    Player.fast_forward()
    {:noreply, socket}
  end

  def handle_event("add_random", _params, socket) do
    live_tracks = Music.add_random_live_tracks()

    {:noreply, reload_tracks(socket, live_tracks)}
  end

  def handle_event("shuffle", _params, socket) do
    live_tracks = Music.refresh_live_tracks()

    {:noreply, reload_tracks(socket, live_tracks, reset_selection: true)}
  end

  def handle_event("delete_track", %{"id" => id}, socket) do
    track_id = String.to_integer(id)
    Music.delete_live_track(track_id)
    live_tracks = Music.list_live_tracks()

    selected = socket.assigns.selected_track

    playing = socket.assigns.playing_track
    is_playing = playing && playing.id == track_id

    socket =
      if selected && selected.id == track_id do
        if is_playing && socket.assigns.player_available do
          Player.stop()
        end

        Config.clear_paused_state()

        socket
        |> assign(:playback_state, :stopped)
        |> assign(:playing_track, nil)
        |> assign(:time_pos, 0.0)
        |> assign(:duration, 0.0)
        |> reload_tracks(live_tracks, reset_selection: true)
      else
        if is_playing && socket.assigns.player_available do
          Player.stop()
        end

        socket =
          if is_playing do
            Config.clear_paused_state()

            socket
            |> assign(:playback_state, :stopped)
            |> assign(:playing_track, nil)
            |> assign(:time_pos, 0.0)
            |> assign(:duration, 0.0)
          else
            socket
          end

        reload_tracks(socket, live_tracks)
      end

    {:noreply, socket}
  end

  def handle_event("move_track", %{"id" => id, "dir" => dir}, socket) do
    track_id = String.to_integer(id)
    direction = if dir == "up", do: :up, else: :down
    live_tracks = Music.move_live_track(track_id, direction)

    {:noreply, reload_tracks(socket, live_tracks)}
  end

  def handle_event("toggle_settings", _params, socket) do
    show = !socket.assigns.show_settings

    socket =
      if show do
        socket
        |> assign(:show_settings, true)
        |> assign(:artists, Music.list_artists())
        |> assign(:editing_artist, nil)
        |> assign(:artist_form, to_form(Music.change_artist(%TuneBox.Music.Artist{})))
      else
        assign(socket, :show_settings, false)
      end

    {:noreply, socket}
  end

  def handle_event("save_artist", %{"artist" => artist_params}, socket) do
    case socket.assigns.editing_artist do
      nil ->
        case Music.create_artist(artist_params) do
          {:ok, _artist} ->
            {:noreply,
             socket
             |> assign(:artists, Music.list_artists())
             |> assign(:artist_form, to_form(Music.change_artist(%TuneBox.Music.Artist{})))}

          {:error, changeset} ->
            {:noreply, assign(socket, :artist_form, to_form(changeset))}
        end

      artist ->
        case Music.update_artist(artist, artist_params) do
          {:ok, _artist} ->
            live_tracks = Music.list_live_tracks()

            {:noreply,
             socket
             |> assign(:artists, Music.list_artists())
             |> assign(:editing_artist, nil)
             |> assign(:artist_form, to_form(Music.change_artist(%TuneBox.Music.Artist{})))
             |> reload_tracks(live_tracks)}

          {:error, changeset} ->
            {:noreply, assign(socket, :artist_form, to_form(changeset))}
        end
    end
  end

  def handle_event("edit_artist", %{"id" => id}, socket) do
    artist = Enum.find(socket.assigns.artists, &(&1.id == String.to_integer(id)))

    {:noreply,
     socket
     |> assign(:editing_artist, artist)
     |> assign(:artist_form, to_form(Music.change_artist(artist)))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_artist, nil)
     |> assign(:artist_form, to_form(Music.change_artist(%TuneBox.Music.Artist{})))}
  end

  def handle_event("edit_track", %{"id" => id}, socket) do
    track = Map.get(socket.assigns.track_map, String.to_integer(id))

    if track do
      changeset = Music.change_track(track)

      {:noreply,
       socket
       |> assign(:editing_track, track)
       |> assign(:track_form, to_form(changeset))
       |> assign(:all_artists, Music.list_artists())
       |> assign(:all_albums, Music.list_albums())
       |> stream(:tracks, socket.assigns.track_list, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_track_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_track, nil)
     |> assign(:track_form, nil)
     |> stream(:tracks, socket.assigns.track_list, reset: true)}
  end

  def handle_event("save_track", %{"track" => track_params}, socket) do
    track = socket.assigns.editing_track

    case Music.update_track(track, track_params) do
      {:ok, _updated} ->
        live_tracks = Music.list_live_tracks()
        tracks = Enum.map(live_tracks, & &1.track)
        updated_selected = Enum.find(tracks, &(&1.id == track.id))

        {:noreply,
         socket
         |> assign(:editing_track, nil)
         |> assign(:track_form, nil)
         |> assign(:selected_track, updated_selected)
         |> reload_tracks(live_tracks)}

      {:error, changeset} ->
        {:noreply, assign(socket, :track_form, to_form(changeset))}
    end
  end

  def handle_event("set_max_tracks", %{"max" => max}, socket) do
    max = max |> String.to_integer() |> max(3) |> min(100)
    Config.set_max_visible_tracks(max)
    {:noreply, assign(socket, :max_visible_tracks, max)}
  end

  def handle_event("toggle_remove_completed_tracks", _params, socket) do
    new_value = !socket.assigns.remove_completed_tracks
    Config.set_remove_completed_tracks(new_value)
    {:noreply, assign(socket, :remove_completed_tracks, new_value)}
  end

  def handle_event("delete_artist", %{"id" => id}, socket) do
    artist = Enum.find(socket.assigns.artists, &(&1.id == String.to_integer(id)))

    if artist do
      Music.delete_artist(artist)
      live_tracks = Music.list_live_tracks()

      {:noreply,
       socket
       |> assign(:artists, Music.list_artists())
       |> assign(:total_tracks, Music.count_tracks())
       |> reload_tracks(live_tracks, reset_selection: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:import_done, socket) do
    socket =
      socket
      |> assign(:importing, false)
      |> assign(:import_current_folder, nil)
      |> assign(:total_tracks, Music.count_tracks())
      |> put_flash(:info, "Library imported")

    {:noreply, socket}
  end

  def handle_info({:import_progress, folder}, socket) do
    {:noreply, assign(socket, :import_current_folder, folder)}
  end

  def handle_info(:track_ended, socket) do
    if socket.assigns.playback_state == :playing do
      if socket.assigns.remove_completed_tracks do
        {:noreply, remove_completed_and_advance(socket, socket.assigns.playing_track)}
      else
        {:noreply, select_adjacent_track(socket, 1)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:time_pos, pos}, socket) do
    {:noreply, assign(socket, :time_pos, pos)}
  end

  def handle_info({:duration, dur}, socket) do
    {:noreply, assign(socket, :duration, dur)}
  end

  def handle_info(:reload_tracks, socket) do
    {:noreply, reload_tracks(socket, Music.list_live_tracks())}
  end

  def handle_info({:import_error, message}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_current_folder, nil)
     |> assign(:import_error, message)}
  end

  defp reload_tracks(socket, live_tracks, opts \\ []) do
    tracks = Enum.map(live_tracks, & &1.track)

    socket =
      socket
      |> assign(:track_list, tracks)
      |> assign(:track_map, Map.new(tracks, &{&1.id, &1}))
      |> stream(:tracks, tracks, reset: true)

    if Keyword.get(opts, :reset_selection, false) do
      assign(socket, :selected_track, nil)
    else
      socket
    end
  end

  defp select_adjacent_track(socket, offset) do
    %{track_list: track_list, selected_track: selected} = socket.assigns

    case track_list do
      [] ->
        socket

      _ ->
        current_index =
          if selected do
            Enum.find_index(track_list, &(&1.id == selected.id)) || 0
          else
            if offset > 0, do: -1, else: length(track_list)
          end

        len = length(track_list)
        new_index = rem(current_index + offset + len, len)
        new_track = Enum.at(track_list, new_index)
        was_playing = socket.assigns.playback_state == :playing

        socket =
          socket
          |> assign(:selected_track, new_track)
          |> stream(:tracks, track_list, reset: true)

        maybe_fetch_artwork(new_track)

        if was_playing and socket.assigns.player_available do
          Player.play(new_track.file_path)
          assign(socket, :playing_track, new_track)
        else
          socket
        end
    end
  end

  defp remove_completed_and_advance(socket, nil), do: select_adjacent_track(socket, 1)

  defp remove_completed_and_advance(socket, completed_track) do
    track_list = socket.assigns.track_list
    current_index = Enum.find_index(track_list, &(&1.id == completed_track.id))

    if current_index == nil do
      select_adjacent_track(socket, 1)
    else
      Music.delete_live_track(completed_track.id)
      new_list = List.delete_at(track_list, current_index)

      socket =
        socket
        |> assign(:track_list, new_list)
        |> assign(:track_map, Map.new(new_list, &{&1.id, &1}))

      case new_list do
        [] ->
          socket
          |> assign(:selected_track, nil)
          |> assign(:playing_track, nil)
          |> assign(:playback_state, :stopped)
          |> stream(:tracks, [], reset: true)

        _ ->
          new_index = min(current_index, length(new_list) - 1)
          new_track = Enum.at(new_list, new_index)

          Player.play(new_track.file_path)
          maybe_fetch_artwork(new_track)

          socket
          |> assign(:selected_track, new_track)
          |> assign(:playing_track, new_track)
          |> stream(:tracks, new_list, reset: true)
      end
    end
  end

  defp maybe_fetch_artwork(track) do
    parent = self()

    Task.start(fn ->
      ArtworkFetcher.fetch_for_track(track)
      send(parent, :reload_tracks)
    end)
  end

  defp format_time(seconds) when is_number(seconds) do
    total = round(seconds)
    m = div(total, 60)
    s = rem(total, 60)
    "#{m}:#{String.pad_leading(Integer.to_string(s), 2, "0")}"
  end

  defp format_time(_), do: "0:00"

  defp progress_percent(pos, dur) when is_number(dur) and dur > 0, do: pos / dur * 100
  defp progress_percent(_, _), do: 0.0

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="text-center mb-6">
        <div class="flex items-center justify-center gap-2">
          <h1 class="text-4xl font-bold tracking-tight">TuneBox</h1>
          <button class="btn btn-ghost btn-sm btn-square" title="Settings" phx-click="toggle_settings">
            <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
          </button>
        </div>
        <p class="mt-2 text-base-content/60">
          Your personal music library, containing {@total_tracks} tracks
        </p>
        <div class="relative mt-3 max-w-md mx-auto">
          <form phx-change="search" phx-submit="search">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search tracks..."
              class="input input-bordered input-sm w-full"
              autocomplete="off"
              phx-debounce="300"
            />
          </form>
          <ul
            :if={@search_results != []}
            class="absolute z-10 w-full mt-1 bg-base-200 rounded-lg shadow-lg max-h-80 overflow-y-auto"
          >
            <li
              :for={track <- @search_results}
              class="flex items-center justify-between gap-2 px-3 py-2 hover:bg-base-300 transition-colors"
            >
              <div class="min-w-0">
                <div class="truncate text-sm font-medium">{track.title}</div>
                <div class="truncate text-xs opacity-60">{track.artist.name}</div>
              </div>
              <button
                class="btn btn-ghost btn-xs btn-square flex-shrink-0"
                title="Add to Live Tracks"
                phx-click="add_to_live"
                phx-value-id={track.id}
              >
                <.icon name="hero-plus" class="w-3.5 h-3.5" />
              </button>
            </li>
          </ul>
        </div>
      </div>

      <div :if={@show_settings} class="card bg-base-200 shadow-sm mb-4">
        <div class="card-body p-4">
          <h2 class="card-title text-base mb-2">Manage Artists</h2>
          <.form for={@artist_form} phx-submit="save_artist" class="flex gap-2 items-start mb-3">
            <div class="flex-1">
              <.input
                field={@artist_form[:name]}
                placeholder="Artist name"
                class="input input-bordered input-sm w-full"
              />
            </div>
            <button type="submit" class="btn btn-primary btn-sm">
              {if @editing_artist, do: "Update", else: "Add"}
            </button>
            <button
              :if={@editing_artist}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="cancel_edit"
            >
              Cancel
            </button>
          </.form>
          <ul class="space-y-1">
            <li
              :for={artist <- @artists}
              class="flex items-center justify-between px-3 py-2 rounded-lg hover:bg-base-300 transition-colors"
            >
              <span class="text-sm">{artist.name}</span>
              <div class="flex items-center gap-1">
                <button
                  class="btn btn-ghost btn-xs btn-square"
                  title="Edit"
                  phx-click="edit_artist"
                  phx-value-id={artist.id}
                >
                  <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                </button>
                <button
                  class="btn btn-ghost btn-xs btn-square text-error"
                  title="Delete"
                  phx-click="delete_artist"
                  phx-value-id={artist.id}
                  data-confirm="Delete this artist and all their tracks?"
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </div>
            </li>
          </ul>
          <p :if={@artists == []} class="text-sm opacity-50 text-center py-2">No artists yet.</p>
          <div class="mt-4 pt-4 border-t border-base-content/10 flex items-center gap-3">
            <span class="text-sm">Max visible tracks</span>
            <form phx-change="set_max_tracks">
              <input
                type="number"
                name="max"
                value={@max_visible_tracks}
                min="3"
                max="100"
                class="input input-bordered input-sm w-20 text-center"
              />
            </form>
          </div>
          <div class="mt-3 flex items-center gap-3">
            <input
              type="checkbox"
              id="remove_completed_tracks"
              class="checkbox checkbox-sm"
              checked={@remove_completed_tracks}
              phx-click="toggle_remove_completed_tracks"
            />
            <label for="remove_completed_tracks" class="text-sm cursor-pointer">
              Remove completed tracks
            </label>
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-4">
        <%!-- Track list --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-1">
              <h2 class="card-title text-base">Live Tracks</h2>
              <div class="flex items-center gap-0.5">
                <button
                  class="btn btn-ghost btn-xs"
                  title="Add 10 random tracks"
                  phx-click="add_random"
                >
                  <.icon name="hero-plus" class="w-4 h-4" />
                </button>

              </div>
            </div>
            <ul
              id="tracks"
              phx-update="stream"
              class="space-y-0.5 overflow-y-auto"
              style={"max-height: #{@max_visible_tracks * 2.5}rem"}
            >
              <li
                :for={{dom_id, track} <- @streams.tracks}
                id={dom_id}
                class={[
                  "group flex items-center gap-2 px-3 py-2 rounded-lg cursor-pointer transition-colors",
                  if(@selected_track && @selected_track.id == track.id,
                    do: "bg-primary text-white",
                    else: "hover:bg-base-300"
                  )
                ]}
                title={track.file_path}
                phx-click="select_track"
                phx-value-id={track.id}
              >
                <%= if track.album && track.album.cover_big do %>
                  <img
                    src={"data:image/jpeg;base64,#{Base.encode64(track.album.cover_big)}"}
                    class="w-12 h-12 rounded object-cover flex-shrink-0"
                  />
                <% else %>
                  <.icon
                    name={
                      if @selected_track && @selected_track.id == track.id,
                        do: "hero-speaker-wave",
                        else: "hero-musical-note"
                    }
                    class={[
                      "w-4 h-4 flex-shrink-0",
                      cond do
                        @playback_state == :playing && @playing_track && @playing_track.id == track.id ->
                          "animate-bounce text-white"

                        @selected_track && @selected_track.id == track.id ->
                          "text-white"

                        true ->
                          "opacity-60"
                      end
                    ]}
                  />
                <% end %>
                <div class="min-w-0 flex-1">
                  <div class="truncate text-sm font-medium">{track.title}</div>
                  <div class="truncate text-xs opacity-60">
                    {track.artist.name}{if track.album, do: " - #{track.album.title}"}
                  </div>
                </div>
                <div class={[
                  "flex items-center gap-0.5 flex-shrink-0 transition-opacity",
                  if(@selected_track && @selected_track.id == track.id,
                    do: "opacity-100",
                    else: "opacity-0 group-hover:opacity-100"
                  )
                ]}>
                  <button
                    :if={@selected_track && @selected_track.id == track.id}
                    class="btn btn-ghost btn-xs btn-square"
                    title="Edit track"
                    phx-click="edit_track"
                    phx-value-id={track.id}
                  >
                    <.icon name="hero-cog-6-tooth" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    class="btn btn-ghost btn-xs btn-square"
                    title="Move up"
                    phx-click="move_track"
                    phx-value-id={track.id}
                    phx-value-dir="up"
                  >
                    <.icon name="hero-arrow-up" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    class="btn btn-ghost btn-xs btn-square"
                    title="Move down"
                    phx-click="move_track"
                    phx-value-id={track.id}
                    phx-value-dir="down"
                  >
                    <.icon name="hero-arrow-down" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    class="btn btn-ghost btn-xs btn-square text-error"
                    title="Remove"
                    phx-click="delete_track"
                    phx-value-id={track.id}
                  >
                    <.icon name="hero-trash" class="w-3.5 h-3.5" />
                  </button>
                </div>
                <div
                  :if={@editing_track && @editing_track.id == track.id}
                  class="mt-2 pt-2 border-t border-base-content/10"
                >
                  <.form for={@track_form} phx-submit="save_track" class="flex items-end gap-2">
                    <div class="flex-1">
                      <label class="label label-text text-xs">Artist</label>
                      <select name="track[artist_id]" class="select select-bordered select-sm w-full">
                        <option
                          :for={artist <- @all_artists}
                          value={artist.id}
                          selected={artist.id == @editing_track.artist_id}
                        >
                          {artist.name}
                        </option>
                      </select>
                    </div>
                    <div class="flex-1">
                      <label class="label label-text text-xs">Album</label>
                      <select name="track[album_id]" class="select select-bordered select-sm w-full">
                        <option value="">None</option>
                        <option
                          :for={album <- @all_albums}
                          value={album.id}
                          selected={album.id == @editing_track.album_id}
                        >
                          {album.title}
                        </option>
                      </select>
                    </div>
                    <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_track_edit">
                      Cancel
                    </button>
                  </.form>
                </div>
              </li>
            </ul>
          </div>
        </div>

        <%!-- Player bar --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center gap-6">
              <%!-- Now Playing --%>
              <div class="flex-1 min-w-0">
                <p class="text-xs font-semibold uppercase tracking-wide opacity-50">Now Playing</p>
                <p class="text-sm font-medium truncate mt-0.5">
                  {if @selected_track, do: @selected_track.title, else: "No track selected"}
                </p>
                <p class="text-xs opacity-50 truncate">
                  {if @selected_track, do: @selected_track.artist.name, else: ""}
                </p>
              </div>

              <%!-- Transport controls --%>
              <div class="flex items-center gap-1 flex-shrink-0">
                <button
                  class="btn btn-ghost btn-circle btn-sm"
                  title="Previous track"
                  phx-click="prev_track"
                  disabled={@track_list == []}
                >
                  <.icon name="hero-backward" class="w-4 h-4" />
                </button>
                <button
                  class="btn btn-ghost btn-circle btn-sm"
                  title="Rewind 10 seconds"
                  phx-click="rewind"
                  disabled={@playback_state == :stopped}
                >
                  <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                </button>
                <button
                  class="btn btn-ghost btn-circle btn-sm"
                  title="Stop"
                  phx-click="stop"
                  disabled={@playback_state == :stopped}
                >
                  <.icon name="hero-stop" class="w-4 h-4" />
                </button>
                <button
                  :if={@playback_state != :playing}
                  class="btn btn-primary btn-circle"
                  title="Play"
                  phx-click="play"
                  disabled={is_nil(@selected_track)}
                >
                  <.icon name="hero-play" class="w-5 h-5" />
                </button>
                <button
                  :if={@playback_state == :playing}
                  class="btn btn-primary btn-circle"
                  title="Pause"
                  phx-click="pause"
                >
                  <.icon name="hero-pause" class="w-5 h-5" />
                </button>
                <button
                  class="btn btn-ghost btn-circle btn-sm"
                  title="Fast forward 10 seconds"
                  phx-click="fast_forward"
                  disabled={@playback_state == :stopped}
                >
                  <.icon name="hero-arrow-uturn-right" class="w-4 h-4" />
                </button>
                <button
                  class="btn btn-ghost btn-circle btn-sm"
                  title="Next track"
                  phx-click="next_track"
                  disabled={@track_list == []}
                >
                  <.icon name="hero-forward" class="w-4 h-4" />
                </button>
              </div>

              <%!-- Import --%>
              <div class="flex-shrink-0 flex flex-col gap-1">
                <p class="text-xs font-semibold uppercase tracking-wide opacity-50 mb-1">
                  Music Library
                </p>
                <form phx-submit="import" class="flex gap-2 items-start">
                  <div class="flex flex-col gap-1">
                    <input
                      type="text"
                      name="path"
                      value={@music_library_path}
                      placeholder="/home/user/Music"
                      class="input input-bordered input-sm w-48"
                      disabled={@importing}
                    />
                    <p :if={@import_error} class="text-xs text-error">{@import_error}</p>
                  </div>
                  <button type="submit" class="btn btn-primary btn-sm" disabled={@importing}>
                    <.icon :if={@importing} name="hero-arrow-path" class="w-4 h-4 animate-spin" />
                    {if @importing, do: "Importing…", else: "Import"}
                  </button>
                </form>
                <p
                  :if={@importing && @import_current_folder}
                  class="text-xs opacity-50 truncate"
                  title={@import_current_folder}
                >
                  {@import_current_folder}
                </p>
              </div>
            </div>

            <%!-- Progress bar --%>
            <div :if={@playback_state != :stopped} class="flex items-center gap-3 mt-2">
              <span class="text-xs tabular-nums opacity-60 w-10 text-right">
                {format_time(@time_pos)}
              </span>
              <div class="flex-1 h-1.5 bg-base-300 rounded-full overflow-hidden">
                <div
                  class="h-full bg-primary rounded-full transition-[width] duration-500 ease-linear"
                  style={"width: #{progress_percent(@time_pos, @duration)}%"}
                />
              </div>
              <span class="text-xs tabular-nums opacity-60 w-10">
                {format_time(@duration)}
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
