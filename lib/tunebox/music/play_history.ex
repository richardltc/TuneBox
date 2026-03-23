defmodule TuneBox.Music.PlayHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "play_history" do
    field(:played_at, :naive_datetime)

    belongs_to(:track, TuneBox.Music.Track)

    timestamps()
  end

  def changeset(play_history, attrs) do
    play_history
    |> cast(attrs, [:track_id, :played_at])
    |> validate_required([:track_id, :played_at])
    |> foreign_key_constraint(:track_id)
  end
end
