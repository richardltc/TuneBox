defmodule TuneBox.Repo.Migrations.AddPausedDurationToConfig do
  use Ecto.Migration

  def change do
    alter table(:config) do
      add :paused_duration, :float, default: 0.0
    end
  end
end
