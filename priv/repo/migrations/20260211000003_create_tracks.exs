defmodule TuneBox.Repo.Migrations.CreateTracks do
  use Ecto.Migration

  def change do
    create table(:tracks) do
      add(:title, :string, null: false)
      add(:album_id, references(:albums, on_delete: :delete_all))
      add(:artist_id, references(:artists, on_delete: :delete_all), null: false)
      add(:track_number, :integer)
      add(:disc_number, :integer, default: 1)
      add(:duration_seconds, :integer)
      add(:file_path, :string, null: false)
      add(:file_format, :string)
      add(:file_size, :integer)
      add(:bit_rate, :integer)
      add(:sample_rate, :integer)

      timestamps()
    end

    create(unique_index(:tracks, [:file_path]))
    create(index(:tracks, [:album_id]))
    create(index(:tracks, [:artist_id]))
    create(index(:tracks, [:title]))
  end
end
