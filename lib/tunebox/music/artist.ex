defmodule TuneBox.Music.Artist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "artists" do
    field(:name, :string)
    field(:picture_big, :binary)

    has_many(:albums, TuneBox.Music.Album)
    has_many(:tracks, TuneBox.Music.Track)

    timestamps()
  end

  def changeset(artist, attrs) do
    artist
    |> cast(attrs, [:name, :picture_big])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
