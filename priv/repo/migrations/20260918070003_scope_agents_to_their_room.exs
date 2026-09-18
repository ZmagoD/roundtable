defmodule Roundtable.Repo.Migrations.ScopeAgentsToTheirRoom do
  use Ecto.Migration

  @moduledoc """
  A room is a project: everyone in it works on the same tree.

  Participants used to be able to sit in a directory of their own, which made
  "what is this room working on" a question with several answers. Existing rows
  are brought onto their room's directory.
  """

  def up do
    execute """
    UPDATE agents
    SET directory = (SELECT directory FROM rooms WHERE rooms.id = agents.room_id)
    WHERE directory IS NOT (SELECT directory FROM rooms WHERE rooms.id = agents.room_id)
    """
  end

  # The old directories are not recorded anywhere, so this cannot be undone.
  def down, do: :ok
end
