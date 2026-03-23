defmodule TuneBox.Repo.Migrations.AddAccordionStateToConfig do
  use Ecto.Migration

  def change do
    alter table(:config) do
      add :show_convert, :boolean, default: false, null: false
      add :show_history, :boolean, default: false, null: false
      add :show_import, :boolean, default: false, null: false
    end
  end
end
