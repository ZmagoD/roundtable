defmodule Roundtable.Repo.Migrations.GiveARoomAnAutoMode do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :auto_mode, :boolean, null: false, default: false
    end

    # The document revision a turn started against, so the auto-mode loop can
    # tell a turn that moved the work forward from one that only ended.
    alter table(:runs) do
      add :work_revision, :integer
    end
  end
end
