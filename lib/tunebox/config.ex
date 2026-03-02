defmodule TuneBox.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "config" do
    field(:music_library_path, :string)
    field(:max_visible_tracks, :integer, default: 10)
    field(:paused_time_pos, :float, default: 0.0)
    field(:paused_duration, :float, default: 0.0)
    field(:remove_completed_tracks, :boolean, default: false)

    belongs_to :paused_track, TuneBox.Music.Track

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :music_library_path,
      :max_visible_tracks,
      :paused_track_id,
      :paused_time_pos,
      :paused_duration,
      :remove_completed_tracks
    ])
  end

  @doc """
  Returns the single config row, creating it if it doesn't exist..
  """
  def get do
    case TuneBox.Repo.one(__MODULE__) do
      nil -> TuneBox.Repo.insert!(%__MODULE__{})
      config -> config
    end
  end

  @doc """
  Returns the stored music library path, or nil if not set.
  """
  def music_library_path do
    get().music_library_path
  end

  @doc """
  Sets the music library path.
  """
  def set_music_library_path(path) do
    get()
    |> changeset(%{music_library_path: path})
    |> TuneBox.Repo.update!()
  end

  @doc """
  Returns the stored max visible tracks setting.
  """
  def max_visible_tracks do
    get().max_visible_tracks || 10
  end

  @doc """
  Sets the max visible tracks value (clamped to 3–100).
  """
  def set_max_visible_tracks(value) do
    value = value |> max(3) |> min(100)

    get()
    |> changeset(%{max_visible_tracks: value})
    |> TuneBox.Repo.update!()
  end

  @doc """
  Saves the paused track ID and time position.
  """
  def set_paused_state(track_id, time_pos, duration) do
    get()
    |> changeset(%{
      paused_track_id: track_id,
      paused_time_pos: time_pos || 0.0,
      paused_duration: duration || 0.0
    })
    |> TuneBox.Repo.update!()
  end

  @doc """
  Clears the paused state (sets track to nil, time/duration to 0.0).
  """
  def clear_paused_state do
    get()
    |> changeset(%{paused_track_id: nil, paused_time_pos: 0.0, paused_duration: 0.0})
    |> TuneBox.Repo.update!()
  end

  @doc """
  Returns whether completed tracks should be removed from the live list.
  """
  def remove_completed_tracks? do
    get().remove_completed_tracks || false
  end

  @doc """
  Sets whether completed tracks should be removed from the live list.
  """
  def set_remove_completed_tracks(value) when is_boolean(value) do
    get()
    |> changeset(%{remove_completed_tracks: value})
    |> TuneBox.Repo.update!()
  end

  @doc """
  Returns `{track_id, time_pos, duration}` if a paused track is saved, or `nil`.
  """
  def get_paused_state do
    config = get()

    if config.paused_track_id do
      {config.paused_track_id, config.paused_time_pos || 0.0, config.paused_duration || 0.0}
    else
      nil
    end
  end
end
