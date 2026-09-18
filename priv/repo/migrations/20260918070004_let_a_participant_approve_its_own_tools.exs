defmodule Roundtable.Repo.Migrations.LetAParticipantApproveItsOwnTools do
  use Ecto.Migration

  @moduledoc """
  An orchestrator that stops at every tool call is not orchestrating.

  Off for everyone who already exists: an agent only stops asking when someone
  says so.
  """

  def change do
    alter table(:agents) do
      add :auto_approve, :boolean, default: false, null: false
    end
  end
end
