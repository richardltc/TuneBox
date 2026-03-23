defmodule TuneBox.Music.QueuedTrack do
  use Ecto.Schema
  import Ecto.Changeset

  schema "queued_tracks" do
    field(:position, :integer)

    belongs_to(:track, TuneBox.Music.Track)

    timestamps()
  end

  def changeset(queued_track, attrs) do
    queued_track
    |> cast(attrs, [:position, :track_id])
    |> validate_required([:position, :track_id])
    |> unique_constraint(:track_id)
    |> foreign_key_constraint(:track_id)
  end
end
