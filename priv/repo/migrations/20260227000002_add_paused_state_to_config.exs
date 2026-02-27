defmodule TuneBox.Repo.Migrations.AddPausedStateToConfig do
  use Ecto.Migration

  def change do
    alter table(:config) do
      add :paused_track_id, references(:tracks, on_delete: :nilify_all)
      add :paused_time_pos, :float, default: 0.0
    end
  end
end
