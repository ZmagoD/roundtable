defmodule Roundtable.Repo.Migrations.AddTaskCheckoutsToRooms do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :checkout_supervisor_id, references(:agents, on_delete: :nilify_all)
      add :checkout_id, :string
      add :checkout_branch, :string
      add :checkout_finished, :boolean, default: false, null: false
    end
  end
end
