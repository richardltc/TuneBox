defmodule JukeBox.Repo.Migrations.CreateArtists do
  use Ecto.Migration

  def change do
    create table(:artists) do
      add(:name, :string, null: false)

      timestamps()
    end

    create(unique_index(:artists, [:name]))
  end
end
