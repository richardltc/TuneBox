defmodule TuneBox.Repo.Migrations.CreateLiveTracks do
  use Ecto.Migration

  def change do
    create table(:live_tracks) do
      add :position, :integer, null: false
      add :track_id, references(:tracks, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:live_tracks, [:track_id])
    create index(:live_tracks, [:position])
  end
end
