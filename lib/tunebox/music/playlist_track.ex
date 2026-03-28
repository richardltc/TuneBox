defmodule TuneBox.Music.PlaylistTrack do
  use Ecto.Schema
  import Ecto.Changeset

  schema "playlist_tracks" do
    field(:position, :integer)

    belongs_to(:playlist, TuneBox.Music.Playlist)
    belongs_to(:track, TuneBox.Music.Track)

    timestamps()
  end

  def changeset(playlist_track, attrs) do
    playlist_track
    |> cast(attrs, [:position, :playlist_id, :track_id])
    |> validate_required([:position, :playlist_id, :track_id])
    |> unique_constraint([:playlist_id, :track_id])
    |> foreign_key_constraint(:playlist_id)
    |> foreign_key_constraint(:track_id)
  end
end
