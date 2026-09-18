defmodule Roundtable.Repo.Migrations.RememberTheRoleASessionWasGiven do
  use Ecto.Migration

  @moduledoc """
  What a participant was told it was for, when its session began.

  A provider session keeps every earlier turn, each with the role it was given
  then. Knowing which one that was is what lets a later turn say the role has
  changed instead of leaving two briefs in the transcript with nothing to tell
  them apart.
  """

  def change do
    alter table(:agents) do
      add :session_role, :string
    end
  end
end
