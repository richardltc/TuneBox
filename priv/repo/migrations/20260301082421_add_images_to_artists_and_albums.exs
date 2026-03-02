defmodule TuneBox.Repo.Migrations.AddImagesToArtistsAndAlbums do
  use Ecto.Migration

  def change do
    alter table(:artists) do
      add :picture_big, :binary
    end

    alter table(:albums) do
      add :cover_big, :binary
    end
  end
end
