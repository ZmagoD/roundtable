defmodule Roundtable.Repo.Migrations.NameSchedules do
  use Ecto.Migration

  def change do
    alter table(:schedules) do
      add :name, :string, null: false, default: "Untitled schedule"
    end
  end
end
