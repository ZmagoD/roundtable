defmodule Roundtable.Repo.Migrations.LetATeamInheritItsProjectsFolder do
  use Ecto.Migration

  @moduledoc """
  Lets a team work in its project's folder without naming one of its own.

  A room whose directory is the empty string inherits its organization's.
  Rooms keep their column as NOT NULL — SQLite cannot ALTER a column to
  nullable, and rebuilding the table takes every referencing row down with
  the dropped original, so inheriting is spelled "" rather than NULL.
  """

  def up do
    alter table(:agents) do
      add :session_directory, :string
    end

    # A session opened before this column existed was opened in the
    # participant's directory: directories could not move until now.
    execute("UPDATE agents SET session_directory = directory WHERE session_id IS NOT NULL")
  end

  def down do
    # Restore what each team worked in before it could inherit, so the
    # column can go back to NOT NULL without losing anyone's folder.
    execute("""
    UPDATE rooms SET directory = COALESCE(
      (SELECT directory FROM organizations WHERE organizations.id = rooms.organization_id),
      directory
    ) WHERE directory = ''
    """)

    alter table(:agents) do
      remove :session_directory
    end
  end
end
