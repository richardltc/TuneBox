defmodule TuneBox.Repo.Migrations.CreatePlayHistory do
  use Ecto.Migration

  def change do
    create table(:play_history) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :played_at, :naive_datetime, null: false

      timestamps()
    end

    create index(:play_history, [:played_at])
    create index(:play_history, [:track_id])
  end
end
