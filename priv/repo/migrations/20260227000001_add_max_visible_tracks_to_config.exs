defmodule TuneBox.Repo.Migrations.AddMaxVisibleTracksToConfig do
  use Ecto.Migration

  def change do
    alter table(:config) do
      add :max_visible_tracks, :integer, default: 10
    end
  end
end
