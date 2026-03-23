defmodule TuneBox.Repo.Migrations.AddPlayCountToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :play_count, :integer, default: 0, null: false
    end
  end
end
