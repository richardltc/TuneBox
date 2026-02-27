defmodule TuneBox.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "config" do
    field(:music_library_path, :string)
    field(:max_visible_tracks, :integer, default: 10)

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:music_library_path, :max_visible_tracks])
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
end
