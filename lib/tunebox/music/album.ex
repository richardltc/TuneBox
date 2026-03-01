defmodule TuneBox.Music.Album do
  use Ecto.Schema
  import Ecto.Changeset

  schema "albums" do
    field(:title, :string)
    field(:year, :integer)
    field(:genre, :string)
    field(:cover_big, :binary)

    belongs_to(:artist, TuneBox.Music.Artist)
    has_many(:tracks, TuneBox.Music.Track)

    timestamps()
  end

  def changeset(album, attrs) do
    album
    |> cast(attrs, [:title, :artist_id, :year, :genre, :cover_big])
    |> validate_required([:title, :artist_id])
    |> foreign_key_constraint(:artist_id)
    |> unique_constraint([:title, :artist_id])
  end
end
