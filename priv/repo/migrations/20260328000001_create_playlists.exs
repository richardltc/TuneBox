defmodule TuneBox.Repo.Migrations.CreatePlaylists do
  use Ecto.Migration

  def change do
    create table(:playlists) do
      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:playlists, [:name])

    create table(:playlist_tracks) do
      add :position, :integer, null: false
      add :playlist_id, references(:playlists, on_delete: :delete_all), null: false
      add :track_id, references(:tracks, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:playlist_tracks, [:playlist_id, :track_id])
    create index(:playlist_tracks, [:playlist_id])
  end
end
