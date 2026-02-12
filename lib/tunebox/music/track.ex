defmodule TuneBox.Music.Track do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tracks" do
    field(:title, :string)
    field(:track_number, :integer)
    field(:disc_number, :integer, default: 1)
    field(:duration_seconds, :integer)
    field(:file_path, :string)
    field(:file_format, :string)
    field(:file_size, :integer)
    field(:bit_rate, :integer)
    field(:sample_rate, :integer)

    belongs_to(:artist, TuneBox.Music.Artist)
    belongs_to(:album, TuneBox.Music.Album)

    timestamps()
  end

  def changeset(track, attrs) do
    track
    |> cast(attrs, [
      :title,
      :album_id,
      :artist_id,
      :track_number,
      :disc_number,
      :duration_seconds,
      :file_path,
      :file_format,
      :file_size,
      :bit_rate,
      :sample_rate
    ])
    |> validate_required([:title, :artist_id, :file_path])
    |> unique_constraint(:file_path)
    |> foreign_key_constraint(:artist_id)
    |> foreign_key_constraint(:album_id)
  end
end
