defmodule TuneBox.Music.Playlist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "playlists" do
    field(:name, :string)

    has_many(:playlist_tracks, TuneBox.Music.PlaylistTrack)

    timestamps()
  end

  def changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
