defmodule TuneBox.Repo.Migrations.CreateAlbums do
  use Ecto.Migration

  def change do
    create table(:albums) do
      add(:title, :string, null: false)
      add(:artist_id, references(:artists, on_delete: :delete_all), null: false)
      add(:year, :integer)
      add(:genre, :string)

      timestamps()
    end

    create(index(:albums, [:artist_id]))
    create(unique_index(:albums, [:title, :artist_id]))
  end
end
