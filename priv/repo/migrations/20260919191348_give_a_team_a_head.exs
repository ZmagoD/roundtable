defmodule Roundtable.Repo.Migrations.GiveATeamAHead do
  use Ecto.Migration

  @moduledoc """
  The one participant in a team you talk to, who hands work to the rest.

  A partial unique index rather than a check in the changeset: two clients
  write to this database, and "exactly one head" is the kind of rule that
  survives a race only if the database is the one holding it.

  Existing teams get no head. Choosing one is a decision about how a team is
  run, and picking whoever happens to be first would be a guess presented as
  a setting.
  """

  def change do
    alter table(:agents) do
      add :head, :boolean, default: false, null: false
    end

    create unique_index(:agents, [:room_id],
             where: "head = 1",
             name: :agents_one_head_per_room
           )
  end
end
