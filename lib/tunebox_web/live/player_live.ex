defmodule TuneboxWeb.PlayerLive do
  use TuneboxWeb, :live_view

  alias TuneBox.Config
  alias TuneBox.Music
  alias TuneBox.Music.{ArtworkFetcher, Importer}
  alias TuneBox.Player

  def mount(_params, _session, socket) do
    queued_tracks = Music.list_queued_tracks()
    tracks = Enum.map(queued_tracks, & &1.track)
    track_map = Map.new(tracks, &{&1.id, &1})

    player_available = Process.whereis(TuneBox.Player) != nil

    if connected?(socket), do: Phoenix.PubSub.subscribe(Tunebox.PubSub, "player:status")

    file_map = Map.new(tracks, &{&1.file_path, &1})

    {restored_track, restored_playing_track, restored_time, restored_duration, restored_playback_state, missed_ended_file} =
      cond do
        connected?(socket) && player_available ->
          case Player.get_status() do
            {file, paused, time_pos, duration, _last_ended} when is_binary(file) ->
              track = Map.get(file_map, file)
              playback_state = if paused, do: :paused, else: :playing
              playing_track = if paused, do: nil, else: track
              {track, playing_track, time_pos, duration, playback_state, nil}

            {nil, _, _, _, last_ended_file} when is_binary(last_ended_file) ->
              {nil, nil, 0.0, 0.0, :stopped, last_ended_file}

            _ ->
              restore_from_config(track_map)
          end

        true ->
          restore_from_config(track_map)
      end

    socket =
      socket
      |> stream(:tracks, tracks)
      |> assign(:track_list, tracks)
      |> assign(:track_map, track_map)
      |> assign(:selected_track, restored_track)
      |> assign(:playing_track, restored_playing_track)
      |> assign(:playback_state, restored_playback_state)
      |> assign(:player_available, player_available)
      |> assign(:time_pos, restored_time)
      |> assign(:duration, restored_duration)
      |> assign(:importing, false)
      |> assign(:import_error, nil)
      |> assign(:import_current_folder, nil)
      |> assign(:total_tracks, Music.count_tracks())
      |> assign(:music_library_path, Config.music_library_path() || "")
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:search_artists, [])
      |> assign(:search_albums, [])
      |> assign(:expanded_artist, nil)
      |> assign(:expanded_album, nil)
      |> assign(:expanded_tracks, [])
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
      |> assign(:show_convert, Config.show_convert?())
      |> assign(:flac_files, [])
      |> assign(:scanning_flac, false)
      |> assign(:flac_selected, MapSet.new())
      |> assign(:convert_bitrate, "192k")
      |> assign(:converting, false)
      |> assign(:convert_delete_original, false)
      |> assign(:convert_conflicts, nil)
      |> assign(:convert_results, nil)
      |> assign(:show_import, Config.show_import?())
      |> assign(:show_history, Config.show_history?())
      |> assign(:history_tracks, if(Config.show_history?(), do: Music.list_recent_plays(), else: []))
      |> assign(:play_recorded_for, nil)
      |> assign(:time_pos_timer, nil)
      |> assign(:pending_time_pos, nil)

    socket =
      if missed_ended_file && socket.assigns.player_available do
        ended_track = Map.get(file_map, missed_ended_file)
        if ended_track, do: Music.record_play(ended_track.id)

        socket =
          socket
          |> assign(:selected_track, ended_track)
          |> assign(:playing_track, ended_track)
          |> assign(:playback_state, :playing)

        if socket.assigns.remove_completed_tracks do
          remove_completed_and_advance(socket, ended_track)
        else
          select_adjacent_track(socket, 1)
        end
      else
        socket
      end

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
          socket |> assign(:playing_track, new_track) |> assign(:play_recorded_for, nil)
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
    artists = Music.search_artists(query)
    albums = Music.search_albums(query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)
     |> assign(:search_artists, artists)
     |> assign(:search_albums, albums)
     |> assign(:expanded_artist, nil)
     |> assign(:expanded_album, nil)
     |> assign(:expanded_tracks, [])}
  end

  def handle_event("expand_artist", %{"id" => id}, socket) do
    artist_id = String.to_integer(id)

    if socket.assigns.expanded_artist == artist_id do
      {:noreply,
       socket
       |> assign(:expanded_artist, nil)
       |> assign(:expanded_tracks, [])}
    else
      tracks = Music.tracks_for_artist(artist_id)

      {:noreply,
       socket
       |> assign(:expanded_artist, artist_id)
       |> assign(:expanded_album, nil)
       |> assign(:expanded_tracks, tracks)}
    end
  end

  def handle_event("expand_album", %{"id" => id}, socket) do
    album_id = String.to_integer(id)

    if socket.assigns.expanded_album == album_id do
      {:noreply,
       socket
       |> assign(:expanded_album, nil)
       |> assign(:expanded_tracks, [])}
    else
      tracks = Music.tracks_for_album(album_id)

      {:noreply,
       socket
       |> assign(:expanded_album, nil)
       |> assign(:expanded_artist, nil)
       |> assign(:expanded_tracks, tracks)
       |> assign(:expanded_album, album_id)}
    end
  end

  def handle_event("add_to_live", %{"id" => id}, socket) do
    track_id = String.to_integer(id)
    Music.add_queued_track(track_id)
    queued_tracks = Music.list_queued_tracks()

    {:noreply, reload_tracks(socket, queued_tracks)}
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
     |> assign(:play_recorded_for, nil)
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
    queued_tracks = Music.add_random_queued_tracks()

    {:noreply, reload_tracks(socket, queued_tracks)}
  end

  def handle_event("shuffle", _params, socket) do
    queued_tracks = Music.refresh_queued_tracks()

    {:noreply, reload_tracks(socket, queued_tracks, reset_selection: true)}
  end

  def handle_event("delete_track", %{"id" => id}, socket) do
    track_id = String.to_integer(id)
    Music.delete_queued_track(track_id)
    queued_tracks = Music.list_queued_tracks()

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
        |> reload_tracks(queued_tracks, reset_selection: true)
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

        reload_tracks(socket, queued_tracks)
      end

    {:noreply, socket}
  end

  def handle_event("move_track", %{"id" => id, "dir" => dir}, socket) do
    track_id = String.to_integer(id)
    direction = if dir == "up", do: :up, else: :down
    queued_tracks = Music.move_queued_track(track_id, direction)

    {:noreply, reload_tracks(socket, queued_tracks)}
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
            queued_tracks = Music.list_queued_tracks()

            {:noreply,
             socket
             |> assign(:artists, Music.list_artists())
             |> assign(:editing_artist, nil)
             |> assign(:artist_form, to_form(Music.change_artist(%TuneBox.Music.Artist{})))
             |> reload_tracks(queued_tracks)}

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
        queued_tracks = Music.list_queued_tracks()
        tracks = Enum.map(queued_tracks, & &1.track)
        updated_selected = Enum.find(tracks, &(&1.id == track.id))

        {:noreply,
         socket
         |> assign(:editing_track, nil)
         |> assign(:track_form, nil)
         |> assign(:selected_track, updated_selected)
         |> reload_tracks(queued_tracks)}

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
      queued_tracks = Music.list_queued_tracks()

      {:noreply,
       socket
       |> assign(:artists, Music.list_artists())
       |> assign(:total_tracks, Music.count_tracks())
       |> reload_tracks(queued_tracks, reset_selection: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_convert", _params, socket) do
    show = !socket.assigns.show_convert
    Config.set_show_convert(show)
    {:noreply, assign(socket, :show_convert, show)}
  end

  def handle_event("toggle_import", _params, socket) do
    show = !socket.assigns.show_import
    Config.set_show_import(show)
    {:noreply, assign(socket, :show_import, show)}
  end


  def handle_event("toggle_history", _params, socket) do
    show = !socket.assigns.show_history
    Config.set_show_history(show)

    socket =
      if show do
        assign(socket, :history_tracks, Music.list_recent_plays())
      else
        socket
      end

    {:noreply, assign(socket, :show_history, show)}
  end

  def handle_event("toggle_flac_file", %{"path" => path}, socket) do
    selected = socket.assigns.flac_selected

    new_selected =
      if MapSet.member?(selected, path),
        do: MapSet.delete(selected, path),
        else: MapSet.put(selected, path)

    {:noreply, assign(socket, :flac_selected, new_selected)}
  end

  def handle_event("scan_flac", _params, socket) do
    path = socket.assigns.music_library_path

    cond do
      path == "" ->
        {:noreply, put_flash(socket, :error, "Set a music library path first.")}

      not File.dir?(path) ->
        {:noreply, put_flash(socket, :error, "Library folder doesn't exist.")}

      true ->
        parent = self()

        Task.start(fn ->
          files = Path.wildcard(Path.join(path, "**/*.flac"))
          send(parent, {:flac_scan_done, files})
        end)

        {:noreply,
         socket
         |> assign(:scanning_flac, true)
         |> assign(:flac_selected, MapSet.new())}
    end
  end

  def handle_event("toggle_convert_delete_original", _params, socket) do
    {:noreply, assign(socket, :convert_delete_original, !socket.assigns.convert_delete_original)}
  end

  def handle_event("set_convert_bitrate", %{"bitrate" => bitrate}, socket) do
    valid = ["96k", "128k", "192k", "256k", "320k"]
    if bitrate in valid do
      {:noreply, assign(socket, :convert_bitrate, bitrate)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("convert_flac", _params, socket) do
    selected = MapSet.to_list(socket.assigns.flac_selected)

    if selected == [] do
      {:noreply, put_flash(socket, :error, "Select at least one FLAC file to convert.")}
    else
      conflicts = Enum.filter(selected, fn path ->
        File.exists?(Path.rootname(path) <> ".opus")
      end)

      if conflicts == [] do
        {:noreply, do_convert(socket, selected, overwrite: false)}
      else
        {:noreply, assign(socket, :convert_conflicts, conflicts)}
      end
    end
  end

  def handle_event("convert_skip_existing", _params, socket) do
    selected = MapSet.to_list(socket.assigns.flac_selected)
    to_convert = Enum.reject(selected, fn path ->
      File.exists?(Path.rootname(path) <> ".opus")
    end)

    socket = assign(socket, :convert_conflicts, nil)

    if to_convert == [] do
      {:noreply, put_flash(socket, :info, "No new files to convert.")}
    else
      {:noreply, do_convert(socket, to_convert, overwrite: false)}
    end
  end

  def handle_event("convert_overwrite_all", _params, socket) do
    selected = MapSet.to_list(socket.assigns.flac_selected)
    socket = assign(socket, :convert_conflicts, nil)
    {:noreply, do_convert(socket, selected, overwrite: true)}
  end

  def handle_event("dismiss_convert_conflicts", _params, socket) do
    {:noreply, assign(socket, :convert_conflicts, nil)}
  end

  def handle_event("dismiss_convert_results", _params, socket) do
    {:noreply, assign(socket, :convert_results, nil)}
  end

  defp do_convert(socket, paths, opts) do
    bitrate = socket.assigns.convert_bitrate
    delete_original = socket.assigns.convert_delete_original
    overwrite = Keyword.get(opts, :overwrite, false)
    parent = self()

    Task.start(fn ->
      results =
        Enum.map(paths, fn path ->
          original_size = case File.stat(path) do
            {:ok, %{size: s}} -> s
            _ -> nil
          end

          result = case TuneBox.Music.Converter.convert(path,
                 bitrate: bitrate,
                 delete_original: delete_original,
                 overwrite: overwrite
               ) do
            {:ok, output_path} ->
              opus_size = case File.stat(output_path) do
                {:ok, %{size: s}} -> s
                _ -> nil
              end
              {:ok, Path.basename(path), original_size, opus_size}

            {:error, reason} ->
              {:error, Path.basename(path), reason}
          end

          send(parent, {:convert_file_done, result, path})
          result
        end)

      send(parent, {:convert_done, results})
    end)

    assign(socket, :converting, true)
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
    if socket.assigns.playback_state in [:playing, :paused] do
      if socket.assigns.time_pos_timer do
        # Throttle window active — store latest value for trailing update
        {:noreply, assign(socket, :pending_time_pos, pos)}
      else
        # Apply immediately and open a 500ms throttle window
        timer = Process.send_after(self(), :flush_time_pos, 500)
        {:noreply, socket |> apply_time_pos(pos) |> assign(:time_pos_timer, timer)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:flush_time_pos, socket) do
    socket = assign(socket, :time_pos_timer, nil)

    case socket.assigns.pending_time_pos do
      nil ->
        {:noreply, socket}

      pos ->
        if socket.assigns.playback_state in [:playing, :paused] do
          {:noreply, socket |> assign(:pending_time_pos, nil) |> apply_time_pos(pos)}
        else
          {:noreply, assign(socket, :pending_time_pos, nil)}
        end
    end
  end

  def handle_info({:duration, dur}, socket) do
    if socket.assigns.playback_state in [:playing, :paused] do
      {:noreply, assign(socket, :duration, dur)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_tracks, socket) do
    {:noreply, reload_tracks(socket, Music.list_queued_tracks())}
  end

  def handle_info({:flac_scan_done, files}, socket) do
    {:noreply,
     socket
     |> assign(:flac_files, files)
     |> assign(:scanning_flac, false)}
  end

  def handle_info({:convert_file_done, {:ok, _, _, _}, path}, socket) do
    {:noreply,
     socket
     |> assign(:flac_files, List.delete(socket.assigns.flac_files, path))
     |> assign(:flac_selected, MapSet.delete(socket.assigns.flac_selected, path))}
  end

  def handle_info({:convert_file_done, _error_result, _path}, socket) do
    {:noreply, socket}
  end

  def handle_info({:convert_done, results}, socket) do
    {:noreply,
     socket
     |> assign(:converting, false)
     |> assign(:convert_results, results)}
  end

  def handle_info({:import_error, message}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_current_folder, nil)
     |> assign(:import_error, message)}
  end

  defp reload_tracks(socket, queued_tracks, opts \\ []) do
    tracks = Enum.map(queued_tracks, & &1.track)

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
          socket |> assign(:playing_track, new_track) |> assign(:play_recorded_for, nil)
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
      Music.delete_queued_track(completed_track.id)
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
          |> assign(:play_recorded_for, nil)
          |> stream(:tracks, new_list, reset: true)
      end
    end
  end

  defp apply_time_pos(socket, pos) do
    prev_pos = socket.assigns.time_pos
    socket = assign(socket, :time_pos, pos)
    track = socket.assigns.playing_track

    if prev_pos < 10 && pos >= 10 && track && socket.assigns.play_recorded_for != track.id do
      Music.record_play(track.id)

      socket =
        if socket.assigns.show_history do
          assign(socket, :history_tracks, Music.list_recent_plays())
        else
          socket
        end

      assign(socket, :play_recorded_for, track.id)
    else
      socket
    end
  end

  defp restore_from_config(track_map) do
    case Config.get_paused_state() do
      {track_id, time_pos, duration} ->
        case Map.get(track_map, track_id) do
          nil -> {nil, nil, 0.0, 0.0, :stopped, nil}
          track -> {track, nil, time_pos, duration, :paused, nil}
        end

      nil ->
        {nil, nil, 0.0, 0.0, :stopped, nil}
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
            :if={@search_artists != [] or @search_albums != [] or @search_results != []}
            class="absolute z-10 w-full mt-1 bg-base-200 rounded-lg shadow-lg max-h-80 overflow-y-auto"
          >
            <%!-- Artists section --%>
            <%= if @search_artists != [] do %>
              <li class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide opacity-50">
                Artists
              </li>
              <%= for artist <- @search_artists do %>
                <li>
                  <button
                    class="w-full flex items-center justify-between gap-2 px-3 py-2 hover:bg-base-300 transition-colors"
                    phx-click="expand_artist"
                    phx-value-id={artist.id}
                  >
                    <div class="flex items-center gap-2 min-w-0">
                      <%= if artist.picture_big do %>
                        <img
                          src={"data:image/jpeg;base64,#{Base.encode64(artist.picture_big)}"}
                          class="w-10 h-10 rounded-full object-cover flex-shrink-0"
                        />
                      <% else %>
                        <.icon name="hero-user" class="w-4 h-4 opacity-60 flex-shrink-0" />
                      <% end %>
                      <span class="truncate text-sm font-medium">{artist.name}</span>
                    </div>
                    <.icon
                      name={if @expanded_artist == artist.id, do: "hero-chevron-up", else: "hero-chevron-down"}
                      class="w-3.5 h-3.5 opacity-60 flex-shrink-0"
                    />
                  </button>
                  <%= if @expanded_artist == artist.id do %>
                    <ul class="bg-base-300/50">
                      <li
                        :for={track <- @expanded_tracks}
                        class="flex items-center gap-2 px-3 pl-9 py-1.5 hover:bg-base-300 transition-colors"
                      >
                        <%= if track.album && track.album.cover_big do %>
                          <img
                            src={"data:image/jpeg;base64,#{Base.encode64(track.album.cover_big)}"}
                            class="w-10 h-10 rounded object-cover flex-shrink-0"
                          />
                        <% end %>
                        <div class="min-w-0 flex-1">
                          <div class="truncate text-sm">{track.title}</div>
                          <div :if={track.album} class="truncate text-xs opacity-60">
                            {track.album.title}
                          </div>
                        </div>
                        <button
                          class="btn btn-ghost btn-xs btn-square flex-shrink-0"
                          title="Add to Queue"
                          phx-click="add_to_live"
                          phx-value-id={track.id}
                        >
                          <.icon name="hero-plus" class="w-3.5 h-3.5" />
                        </button>
                      </li>
                    </ul>
                  <% end %>
                </li>
              <% end %>
            <% end %>
            <%!-- Albums section --%>
            <%= if @search_albums != [] do %>
              <li class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide opacity-50">
                Albums
              </li>
              <%= for album <- @search_albums do %>
                <li>
                  <button
                    class="w-full flex items-center justify-between gap-2 px-3 py-2 hover:bg-base-300 transition-colors"
                    phx-click="expand_album"
                    phx-value-id={album.id}
                  >
                    <div class="flex items-center gap-2 min-w-0">
                      <%= if album.cover_big do %>
                        <img
                          src={"data:image/jpeg;base64,#{Base.encode64(album.cover_big)}"}
                          class="w-10 h-10 rounded object-cover flex-shrink-0"
                        />
                      <% else %>
                        <.icon name="hero-rectangle-stack" class="w-4 h-4 opacity-60 flex-shrink-0" />
                      <% end %>
                      <div class="min-w-0">
                        <span class="truncate text-sm font-medium">{album.title}</span>
                        <span class="text-xs opacity-60"> - {album.artist.name}</span>
                      </div>
                    </div>
                    <.icon
                      name={if @expanded_album == album.id, do: "hero-chevron-up", else: "hero-chevron-down"}
                      class="w-3.5 h-3.5 opacity-60 flex-shrink-0"
                    />
                  </button>
                  <%= if @expanded_album == album.id do %>
                    <ul class="bg-base-300/50">
                      <li
                        :for={track <- @expanded_tracks}
                        class="flex items-center gap-2 px-3 pl-9 py-1.5 hover:bg-base-300 transition-colors"
                      >
                        <%= if track.album && track.album.cover_big do %>
                          <img
                            src={"data:image/jpeg;base64,#{Base.encode64(track.album.cover_big)}"}
                            class="w-10 h-10 rounded object-cover flex-shrink-0"
                          />
                        <% end %>
                        <div class="min-w-0 flex-1">
                          <div class="truncate text-sm">{track.title}</div>
                        </div>
                        <button
                          class="btn btn-ghost btn-xs btn-square flex-shrink-0"
                          title="Add to Queue"
                          phx-click="add_to_live"
                          phx-value-id={track.id}
                        >
                          <.icon name="hero-plus" class="w-3.5 h-3.5" />
                        </button>
                      </li>
                    </ul>
                  <% end %>
                </li>
              <% end %>
            <% end %>
            <%!-- Tracks section --%>
            <%= if @search_results != [] do %>
              <li class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide opacity-50">
                Tracks
              </li>
              <li
                :for={track <- @search_results}
                class="flex items-center gap-2 px-3 py-2 hover:bg-base-300 transition-colors"
              >
                <%= if track.album && track.album.cover_big do %>
                  <img
                    src={"data:image/jpeg;base64,#{Base.encode64(track.album.cover_big)}"}
                    class="w-10 h-10 rounded object-cover flex-shrink-0"
                  />
                <% end %>
                <div class="min-w-0 flex-1">
                  <div class="truncate text-sm font-medium">{track.title}</div>
                  <div class="truncate text-xs opacity-60">{track.artist.name}</div>
                </div>
                <button
                  class="btn btn-ghost btn-xs btn-square flex-shrink-0"
                  title="Add to Queue"
                  phx-click="add_to_live"
                  phx-value-id={track.id}
                >
                  <.icon name="hero-plus" class="w-3.5 h-3.5" />
                </button>
              </li>
            <% end %>
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
          <ul class="space-y-1 overflow-y-auto" style="max-height: 25rem">
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

      <div class="flex gap-4 items-start">
        <%!-- Left column --%>
        <div class="w-96 flex-shrink-0 flex flex-col gap-4">
          <%!-- Import accordion --%>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body p-0">
              <button
                class="flex items-center justify-between w-full px-4 py-3 text-left hover:bg-base-300 transition-colors rounded-2xl"
                phx-click="toggle_import"
              >
                <div class="flex items-center gap-2">
                  <.icon name="hero-folder-arrow-down" class="w-4 h-4 opacity-70" />
                  <span class="font-semibold text-sm">Import Library</span>
                  <span :if={@importing} class="loading loading-spinner loading-xs opacity-60" />
                </div>
                <.icon
                  name={if @show_import, do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="w-4 h-4 opacity-60"
                />
              </button>
              <div :if={@show_import} class="px-4 pb-4">
                <form phx-submit="import" class="flex gap-2 items-center">
                  <input
                    type="text"
                    name="path"
                    value={@music_library_path}
                    placeholder="/home/user/Music"
                    class="input input-bordered input-sm flex-1"
                    disabled={@importing}
                  />
                  <button type="submit" class="btn btn-primary btn-sm flex-shrink-0" disabled={@importing}>
                    <.icon :if={@importing} name="hero-arrow-path" class="w-4 h-4 animate-spin" />
                    {if @importing, do: "Importing…", else: "Import"}
                  </button>
                </form>
                <p :if={@import_error} class="text-xs text-error mt-1">{@import_error}</p>
                <p
                  :if={@importing && @import_current_folder}
                  class="text-xs opacity-50 truncate mt-1"
                  title={@import_current_folder}
                >
                  {Path.relative_to(@import_current_folder, @music_library_path)}
                </p>
              </div>
            </div>
          </div>

          <%!-- Convert accordion --%>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body p-0">
              <button
                class="flex items-center justify-between w-full px-4 py-3 text-left hover:bg-base-300 transition-colors rounded-2xl"
                phx-click="toggle_convert"
              >
                <div class="flex items-center gap-2">
                  <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4 opacity-70" />
                  <span class="font-semibold text-sm">Convert</span>
                </div>
                <.icon
                  name={if @show_convert, do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="w-4 h-4 opacity-60"
                />
              </button>
              <div :if={@show_convert} class="px-4 pb-4">
                <div class="flex items-center justify-between mb-3">
                  <span class="text-xs opacity-60">
                    {length(@flac_files)} FLAC file{if length(@flac_files) != 1, do: "s", else: ""}
                  </span>
                  <button
                    class="btn btn-primary btn-xs"
                    phx-click="scan_flac"
                    disabled={@scanning_flac}
                  >
                    <.icon :if={@scanning_flac} name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                    {if @scanning_flac, do: "Scanning…", else: "Scan"}
                  </button>
                </div>
                <%!-- Bitrate selector --%>
                <div class="mb-3">
                  <label class="text-xs opacity-60 block mb-1.5">Opus bitrate</label>
                  <div class="flex gap-1.5 flex-wrap">
                    <%= for {label, value} <- [{"96k", "96k"}, {"128k", "128k"}, {"192k", "192k"}, {"256k", "256k"}, {"320k", "320k"}] do %>
                      <button
                        class={[
                          "btn btn-xs",
                          if(@convert_bitrate == value, do: "btn-primary", else: "btn-ghost")
                        ]}
                        phx-click="set_convert_bitrate"
                        phx-value-bitrate={value}
                      >
                        {label}{if value == "192k", do: " ★", else: ""}
                      </button>
                    <% end %>
                  </div>
                </div>
                <ul class="space-y-0.5 overflow-y-auto" style="max-height: 24rem">
                  <li
                    :for={path <- @flac_files}
                    id={"flac-#{:erlang.phash2(path)}"}
                    class="group flex items-center gap-2 px-3 py-2 rounded-lg hover:bg-base-300 transition-colors cursor-pointer"
                    title={path}
                    phx-click="toggle_flac_file"
                    phx-value-path={path}
                  >
                    <input
                      type="checkbox"
                      id={"flac-cb-#{:erlang.phash2(path)}"}
                      class="checkbox checkbox-xs flex-shrink-0"
                      checked={MapSet.member?(@flac_selected, path)}
                      onclick="event.preventDefault()"
                    />
                    <.icon name="hero-musical-note" class="w-4 h-4 flex-shrink-0 opacity-60" />
                    <div class="min-w-0 flex-1">
                      <div class="truncate text-sm font-medium">
                        {Path.basename(path, ".flac")}
                      </div>
                      <div class="truncate text-xs opacity-60">
                        {Path.dirname(path) |> Path.basename()}
                      </div>
                    </div>
                  </li>
                  <li
                    :if={@flac_files == [] and not @scanning_flac}
                    class="text-xs opacity-50 text-center py-4"
                  >
                    Press Scan to find FLAC files
                  </li>
                </ul>
                <%!-- Delete original option --%>
                <div :if={@flac_files != []} class="mt-3 flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="convert_delete_original"
                    class="checkbox checkbox-xs"
                    checked={@convert_delete_original}
                    phx-click="toggle_convert_delete_original"
                  />
                  <label for="convert_delete_original" class="text-xs cursor-pointer select-none">
                    Delete original FLAC after conversion
                  </label>
                </div>
                <%!-- Convert button --%>
                <div :if={@flac_files != []} class="mt-2 flex items-center justify-between">
                  <span class="text-xs opacity-50">
                    {MapSet.size(@flac_selected)} selected
                  </span>
                  <button
                    class="btn btn-primary btn-sm"
                    phx-click="convert_flac"
                    disabled={@converting or MapSet.size(@flac_selected) == 0}
                  >
                    <.icon :if={@converting} name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                    {if @converting, do: "Converting…", else: "Convert to Opus"}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Recently Played accordion --%>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body p-0">
              <button
                class="flex items-center justify-between w-full px-4 py-3 text-sm font-medium hover:bg-base-300 rounded-box transition-colors"
                phx-click="toggle_history"
              >
                <div class="flex items-center gap-2">
                  <.icon name="hero-clock" class="w-4 h-4" />
                  <span>Recently Played</span>
                </div>
                <.icon name={if @show_history, do: "hero-chevron-up", else: "hero-chevron-down"} class="w-4 h-4" />
              </button>
              <div :if={@show_history} class="px-4 pb-4">
                <div :if={@history_tracks == []} class="text-sm opacity-50 py-2">
                  No tracks played yet.
                </div>
                <ul class="flex flex-col gap-1 max-h-[420px] overflow-y-auto">
                  <li
                    :for={entry <- @history_tracks}
                    class="flex items-center gap-2 py-1 text-sm cursor-pointer hover:bg-base-300 rounded px-2 -mx-2"
                    phx-click="add_to_live"
                    phx-value-id={entry.track.id}
                    title={"Add to queue: #{entry.track.title}"}
                  >
                    <%= cond do %>
                      <% entry.track.album && entry.track.album.cover_big -> %>
                        <img
                          src={"data:image/jpeg;base64,#{Base.encode64(entry.track.album.cover_big)}"}
                          class="w-8 h-8 rounded object-cover flex-shrink-0"
                        />
                      <% entry.track.artist.picture_big -> %>
                        <img
                          src={"data:image/jpeg;base64,#{Base.encode64(entry.track.artist.picture_big)}"}
                          class="w-8 h-8 rounded object-cover flex-shrink-0"
                        />
                      <% true -> %>
                        <div class="w-8 h-8 rounded bg-base-300 flex-shrink-0" />
                    <% end %>
                    <div class="flex flex-col min-w-0 flex-1">
                      <span class="truncate font-medium">{entry.track.title}</span>
                      <span class="truncate text-xs opacity-60">{entry.track.artist.name}</span>
                    </div>
                    <div class="flex flex-col items-end gap-0.5 flex-shrink-0">
                      <span class="text-xs opacity-40">{Calendar.strftime(entry.played_at, "%b %d, %H:%M")}</span>
                      <span class="text-xs opacity-40">{entry.track.play_count}×</span>
                    </div>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </div>

        <%!-- Right: main content --%>
        <div class="flex flex-col gap-4 flex-1 min-w-0">
        <%!-- Track list --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-1">
              <h2 class="card-title text-base">Queued Tracks</h2>
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

            </div>

            <%!-- Progress bar --%>
            <div :if={@playback_state != :stopped} class="flex items-center gap-3 mt-2">
              <span class="text-xs tabular-nums opacity-60 w-10 text-right">
                {format_time(@time_pos)}
              </span>
              <div class="flex-1 h-1.5 bg-base-300 rounded-full overflow-hidden">
                <div
                  class="h-full bg-primary rounded-full"
                  style={"width: #{progress_percent(@time_pos, @duration)}%"}
                />
              </div>
              <span class="text-xs tabular-nums opacity-60 w-10">
                {format_time(@duration)}
              </span>
            </div>
          </div>
        </div>
        </div><%!-- /right column --%>
      </div>
      <%!-- Conversion results panel --%>
      <div :if={@convert_results} class="modal modal-open">
        <div class="modal-box max-w-lg">
          <h3 class="font-bold text-lg mb-3">Conversion results</h3>
          <ul class="space-y-2 max-h-80 overflow-y-auto mb-4">
            <li :for={result <- @convert_results}>
              <%= case result do %>
                <% {:ok, name, orig, opus} -> %>
                  <div class="flex items-start gap-2 text-sm">
                    <.icon name="hero-check-circle" class="w-4 h-4 text-success mt-0.5 flex-shrink-0" />
                    <div class="min-w-0">
                      <div class="font-medium truncate">{name}</div>
                      <div class="text-xs opacity-60">
                        {format_bytes(orig)} → {format_bytes(opus)}
                      </div>
                    </div>
                  </div>
                <% {:error, name, _reason} -> %>
                  <div class="flex items-start gap-2 text-sm">
                    <.icon name="hero-x-circle" class="w-4 h-4 text-error mt-0.5 flex-shrink-0" />
                    <div class="font-medium truncate text-error">{name}</div>
                  </div>
              <% end %>
            </li>
          </ul>
          <div class="modal-action">
            <button class="btn btn-primary btn-sm" phx-click="dismiss_convert_results">Done</button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="dismiss_convert_results"></div>
      </div>
      <%!-- Overwrite confirmation modal --%>
      <div :if={@convert_conflicts} class="modal modal-open">
        <div class="modal-box max-w-md">
          <h3 class="font-bold text-lg mb-2">File already exists</h3>
          <p class="text-sm opacity-70 mb-3">
            {length(@convert_conflicts)} .opus file{if length(@convert_conflicts) != 1, do: "s already exist", else: " already exists"}. What would you like to do?
          </p>
          <ul class="text-xs opacity-60 space-y-0.5 mb-4 max-h-40 overflow-y-auto">
            <li :for={path <- @convert_conflicts} class="truncate">
              {Path.basename(path, ".flac")}.opus
            </li>
          </ul>
          <div class="modal-action flex gap-2 justify-end">
            <button class="btn btn-ghost btn-sm" phx-click="dismiss_convert_conflicts">
              Cancel
            </button>
            <button class="btn btn-outline btn-sm" phx-click="convert_skip_existing">
              Skip existing
            </button>
            <button class="btn btn-primary btn-sm" phx-click="convert_overwrite_all">
              Overwrite all
            </button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="dismiss_convert_conflicts"></div>
      </div>
    </Layouts.app>
    """
  end

  defp format_bytes(nil), do: "unknown"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
