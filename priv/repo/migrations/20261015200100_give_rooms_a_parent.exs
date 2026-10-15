defmodule Roundtable.Repo.Migrations.GiveRoomsAParent do
  use Ecto.Migration

  # `Chat.delete_room/1` removes a subtree deepest first itself, so that it can
  # refuse while a descendant holds unpushed work; the cascade is only a
  # backstop for a parent deleted some other way.
  def change do
    alter table(:rooms) do
      add :parent_id, references(:rooms, on_delete: :delete_all)
    end

    create index(:rooms, [:parent_id])

    # Task rooms made before this existed already name their supervisor, whose
    # room is the one that spun them off.
    execute(backfill(), "SELECT 1")
  end

  # Public so the test can run the same statement against rooms it seeds.
  def backfill do
    """
    UPDATE rooms SET parent_id = (
      SELECT a.room_id FROM agents a WHERE a.id = rooms.checkout_supervisor_id
    )
    WHERE parent_id IS NULL
      AND checkout_supervisor_id IS NOT NULL
      AND (SELECT a.room_id FROM agents a WHERE a.id = rooms.checkout_supervisor_id) <> rooms.id
    """
  end
end
