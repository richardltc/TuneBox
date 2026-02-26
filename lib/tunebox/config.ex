defmodule TuneBox.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "config" do
    field(:music_library_path, :string)

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:music_library_path])
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
end
