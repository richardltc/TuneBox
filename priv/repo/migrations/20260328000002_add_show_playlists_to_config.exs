defmodule TuneBox.Repo.Migrations.AddShowPlaylistsToConfig do
  use Ecto.Migration

  def change do
    alter table(:config) do
      add :show_playlists, :boolean, default: false
    end
  end
end
