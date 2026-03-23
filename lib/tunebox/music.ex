defmodule TuneBox.Music do
  import Ecto.Query

  alias TuneBox.Repo
  alias TuneBox.Music.{Album, Artist, Track, QueuedTrack, PlayHistory}

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
  Returns all queued tracks ordered by position, with track and artist preloaded.
  """
  def list_queued_tracks do
    QueuedTrack
    |> order_by(:position)
    |> preload(track: [:artist, :album])
    |> Repo.all()
  end

  @doc """
  Clears the queued_tracks table and inserts `count` random tracks.
  Returns the new list of queued tracks (with track and artist preloaded).
  """
  def refresh_queued_tracks(count \\ 10) do
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
      Repo.delete_all(QueuedTrack)
      Repo.insert_all(QueuedTrack, entries)
    end)

    list_queued_tracks()
  end

  @doc """
  Appends `count` random tracks (not already in the queue) to the end.
  Returns the updated list of queued tracks.
  """
  def add_random_queued_tracks(count \\ 10) do
    existing_ids =
      QueuedTrack
      |> select([qt], qt.track_id)
      |> Repo.all()

    track_ids =
      Track
      |> where([t], t.id not in ^existing_ids)
      |> select([t], t.id)
      |> order_by(fragment("RANDOM()"))
      |> limit(^count)
      |> Repo.all()

    max_position =
      QueuedTrack
      |> select([qt], max(qt.position))
      |> Repo.one() || 0

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      track_ids
      |> Enum.with_index(max_position + 1)
      |> Enum.map(fn {track_id, position} ->
        %{track_id: track_id, position: position, inserted_at: now, updated_at: now}
      end)

    if entries != [], do: Repo.insert_all(QueuedTrack, entries)

    list_queued_tracks()
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
    |> preload([:artist, :album])
    |> Repo.all()
  end

  def search_tracks(_), do: []

  @doc """
  Searches artists by name. Returns up to 5 matches.
  """
  def search_artists(query) when is_binary(query) and query != "" do
    pattern = "%#{query}%"

    Artist
    |> where([a], like(a.name, ^pattern))
    |> limit(5)
    |> Repo.all()
  end

  def search_artists(_), do: []

  @doc """
  Searches albums by title. Returns up to 5 matches with artist preloaded.
  """
  def search_albums(query) when is_binary(query) and query != "" do
    pattern = "%#{query}%"

    Album
    |> where([a], like(a.title, ^pattern))
    |> limit(5)
    |> preload(:artist)
    |> Repo.all()
  end

  def search_albums(_), do: []

  @doc """
  Returns all tracks for an artist, preloaded with artist and album.
  """
  def tracks_for_artist(artist_id) do
    Track
    |> where([t], t.artist_id == ^artist_id)
    |> order_by(:title)
    |> preload([:artist, :album])
    |> Repo.all()
  end

  @doc """
  Returns all tracks for an album, preloaded with artist and album.
  """
  def tracks_for_album(album_id) do
    Track
    |> where([t], t.album_id == ^album_id)
    |> order_by(:track_number)
    |> preload([:artist, :album])
    |> Repo.all()
  end

  @doc """
  Records a play event for the given track_id.
  """
  def record_play(track_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.transaction(fn ->
      %PlayHistory{}
      |> PlayHistory.changeset(%{track_id: track_id, played_at: now})
      |> Repo.insert!()

      Track
      |> where(id: ^track_id)
      |> Repo.update_all(inc: [play_count: 1])
    end)
  end

  @doc """
  Returns the last `limit` play history entries ordered by most recent first,
  with track, artist, and album preloaded.
  """
  def list_recent_plays(limit \\ 50) do
    PlayHistory
    |> order_by(desc: :played_at)
    |> limit(^limit)
    |> preload(track: [:artist, :album])
    |> Repo.all()
  end

  @doc """
  Adds a track to the end of the queue.
  Does nothing if the track is already in the queue.
  """
  def add_queued_track(track_id) do
    if Repo.get_by(QueuedTrack, track_id: track_id) do
      :already_exists
    else
      max_position =
        QueuedTrack
        |> select([qt], max(qt.position))
        |> Repo.one() || 0

      %QueuedTrack{}
      |> QueuedTrack.changeset(%{track_id: track_id, position: max_position + 1})
      |> Repo.insert()
    end
  end

  @doc """
  Removes a track from the queue by track_id.
  """
  def delete_queued_track(track_id) do
    QueuedTrack
    |> where(track_id: ^track_id)
    |> Repo.delete_all()
  end

  @doc """
  Moves a queued track up or down by swapping positions with its neighbor.
  Returns the updated list of queued tracks.
  """
  def move_queued_track(track_id, direction) when direction in [:up, :down] do
    case Repo.get_by(QueuedTrack, track_id: track_id) do
      nil ->
        list_queued_tracks()

      queued_track ->
        neighbor =
          case direction do
            :up ->
              QueuedTrack
              |> where([qt], qt.position < ^queued_track.position)
              |> order_by(desc: :position)
              |> limit(1)
              |> Repo.one()

            :down ->
              QueuedTrack
              |> where([qt], qt.position > ^queued_track.position)
              |> order_by(asc: :position)
              |> limit(1)
              |> Repo.one()
          end

        case neighbor do
          nil ->
            list_queued_tracks()

          neighbor ->
            Repo.transaction(fn ->
              # Temporarily set one to a placeholder to avoid unique constraint issues
              {old_pos, new_pos} = {queued_track.position, neighbor.position}

              queued_track
              |> Ecto.Changeset.change(position: new_pos)
              |> Repo.update!()

              neighbor
              |> Ecto.Changeset.change(position: old_pos)
              |> Repo.update!()
            end)

            list_queued_tracks()
        end
    end
  end
end
