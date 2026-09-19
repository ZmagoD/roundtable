defmodule Roundtable.Repo.Migrations.AddOrganizationIdToRooms do
  use Ecto.Migration

  import Ecto.Query, only: [from: 1, from: 2]

  @moduledoc """
  Puts every room that already exists into one organization.

  Named "Existing workspace" rather than guessed at: the rooms on this machine
  were made before organizations existed, and inventing a project grouping for
  them would be a guess the person has to undo. They can be moved afterwards.

  The column is nullable at the database level and required in the changeset.
  SQLite cannot add a NOT NULL column to a populated table without a constant
  default, and a default would quietly put every future room in whichever
  organization happened to be first.
  """

  def up do
    alter table(:rooms) do
      add :organization_id, references(:organizations, on_delete: :restrict)
    end

    create index(:rooms, [:organization_id])

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().insert_all("organizations", [
      %{name: "Existing workspace", inserted_at: now, updated_at: now}
    ])

    [id] =
      repo().all(from(o in "organizations", where: o.name == "Existing workspace", select: o.id))

    repo().update_all(from(r in "rooms"), set: [organization_id: id])
  end

  def down do
    drop index(:rooms, [:organization_id])

    alter table(:rooms) do
      remove :organization_id
    end

    repo().delete_all(from(o in "organizations", where: o.name == "Existing workspace"))
  end
end
