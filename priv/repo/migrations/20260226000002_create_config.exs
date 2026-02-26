defmodule TuneBox.Repo.Migrations.CreateConfig do
  use Ecto.Migration

  def change do
    create table(:config) do
      add :music_library_path, :string

      timestamps()
    end
  end
end
