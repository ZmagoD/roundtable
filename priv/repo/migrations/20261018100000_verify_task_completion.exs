defmodule Roundtable.Repo.Migrations.VerifyTaskCompletion do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :completion_review, :map, null: false, default: %{}
      add :completion_sealed, :boolean, null: false, default: false
      add :completion_auto, :boolean, null: false, default: false
      add :completion_remove, :boolean, null: false, default: false
    end

    # No foreign keys: the audit has to outlive the task room it describes and,
    # when that room is removed, still be there for a retry of its cleanup.
    create table(:task_closures) do
      add :task_room_id, :integer, null: false
      add :parent_room_id, :integer, null: false
      add :summary, :map, null: false
      add :status, :string, null: false, default: "sealed"
      add :error, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_closures, [:task_room_id])
  end
end
