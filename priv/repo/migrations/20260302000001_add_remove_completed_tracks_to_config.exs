defmodule TuneBox.Repo.Migrations.AddRemoveCompletedTracksToConfig do
  use Ecto.Migration

  def change do
    alter table(:config) do
      add :remove_completed_tracks, :boolean, default: false, null: false
    end
  end
end
