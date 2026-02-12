defmodule TuneBox.Music.Artist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "artists" do
    field(:name, :string)

    has_many(:albums, Jukebox.Music.Album)
    has_many(:tracks, Jukebox.Music.Track)

    timestamps()
  end

  def changeset(artist, attrs) do
    artist
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
