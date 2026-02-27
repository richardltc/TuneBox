defmodule TuneBox.Music do
  import Ecto.Query

  alias TuneBox.Repo
  alias TuneBox.Music.{Album, Artist, Track, LiveTrack}

  def list_artists do
    Artist |> order_by(:name) |> Repo.all()
  end

  def create_artist(attrs) do
    %Artist{} |> Artist.changeset(attrs) |> Repo.insert()
  end

  def update_artist(%Artist{} = artist, attrs) do
    artist |> Artist.changeset(attrs) |> Repo.update()
  end

  def delete_artist(%Artist{} = artist) do
    Repo.delete(artist)
  end

  def change_artist(%Artist{} = artist, attrs \\ %{}) do
    Artist.changeset(artist, attrs)
  end

  def list_albums do
    Album |> order_by(:title) |> Repo.all()
  end

  def update_track(%Track{} = track, attrs) do
    track |> Track.changeset(attrs) |> Repo.update()
  end

  def change_track(%Track{} = track, attrs \\ %{}) do
    Track.changeset(track, attrs)
  end

  @doc """
  Returns the total number of tracks in the library.
  """
  def count_tracks do
    Repo.aggregate(Track, :count)
  end

  @doc """
  Returns all live tracks ordered by position, with track and artist preloaded..
  """
  def list_live_tracks do
    LiveTrack
    |> order_by(:position)
    |> preload(track: :artist)
    |> Repo.all()
  end

  @doc """
  Clears the live_tracks table and inserts `count` random tracks.
  Returns the new list of live tracks (with track and artist preloaded).
  """
  def refresh_live_tracks(count \\ 10) do
    track_ids =
      Track
      |> select([t], t.id)
      |> order_by(fragment("RANDOM()"))
      |> limit(^count)
      |> Repo.all()

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      track_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {track_id, position} ->
        %{track_id: track_id, position: position, inserted_at: now, updated_at: now}
      end)

    Repo.transaction(fn ->
      Repo.delete_all(LiveTrack)
      Repo.insert_all(LiveTrack, entries)
    end)

    list_live_tracks()
  end

  @doc """
  Appends `count` random tracks (not already in the live list) to the end.
  Returns the updated list of live tracks.
  """
  def add_random_live_tracks(count \\ 10) do
    existing_ids =
      LiveTrack
      |> select([lt], lt.track_id)
      |> Repo.all()

    track_ids =
      Track
      |> where([t], t.id not in ^existing_ids)
      |> select([t], t.id)
      |> order_by(fragment("RANDOM()"))
      |> limit(^count)
      |> Repo.all()

    max_position =
      LiveTrack
      |> select([lt], max(lt.position))
      |> Repo.one() || 0

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      track_ids
      |> Enum.with_index(max_position + 1)
      |> Enum.map(fn {track_id, position} ->
        %{track_id: track_id, position: position, inserted_at: now, updated_at: now}
      end)

    if entries != [], do: Repo.insert_all(LiveTrack, entries)

    list_live_tracks()
  end

  @doc """
  Searches tracks by title or artist name. Returns up to 10 results.
  """
  def search_tracks(query) when is_binary(query) and query != "" do
    pattern = "%#{query}%"

    artist_track_ids =
      Track
      |> join(:inner, [t], a in assoc(t, :artist))
      |> where([t, a], like(a.name, ^pattern))
      |> select([t], t.id)

    Track
    |> where([t], like(t.title, ^pattern) or t.id in subquery(artist_track_ids))
    |> limit(10)
    |> preload(:artist)
    |> Repo.all()
  end

  def search_tracks(_), do: []

  @doc """
  Adds a track to the end of the live tracks list.
  Does nothing if the track is already in the list.
  """
  def add_live_track(track_id) do
    if Repo.get_by(LiveTrack, track_id: track_id) do
      :already_exists
    else
      max_position =
        LiveTrack
        |> select([lt], max(lt.position))
        |> Repo.one() || 0

      %LiveTrack{}
      |> LiveTrack.changeset(%{track_id: track_id, position: max_position + 1})
      |> Repo.insert()
    end
  end

  @doc """
  Deletes the live track for the given track_id.
  """
  def delete_live_track(track_id) do
    LiveTrack
    |> where(track_id: ^track_id)
    |> Repo.delete_all()
  end

  @doc """
  Moves a live track up or down by swapping positions with its neighbor.
  Returns the updated list of live tracks.
  """
  def move_live_track(track_id, direction) when direction in [:up, :down] do
    case Repo.get_by(LiveTrack, track_id: track_id) do
      nil ->
        list_live_tracks()

      live_track ->
        neighbor =
          case direction do
            :up ->
              LiveTrack
              |> where([lt], lt.position < ^live_track.position)
              |> order_by(desc: :position)
              |> limit(1)
              |> Repo.one()

            :down ->
              LiveTrack
              |> where([lt], lt.position > ^live_track.position)
              |> order_by(asc: :position)
              |> limit(1)
              |> Repo.one()
          end

        case neighbor do
          nil ->
            list_live_tracks()

          neighbor ->
            Repo.transaction(fn ->
              # Temporarily set one to a placeholder to avoid unique constraint issues
              {old_pos, new_pos} = {live_track.position, neighbor.position}

              live_track
              |> Ecto.Changeset.change(position: new_pos)
              |> Repo.update!()

              neighbor
              |> Ecto.Changeset.change(position: old_pos)
              |> Repo.update!()
            end)

            list_live_tracks()
        end
    end
  end
end
