defmodule Roundtable.Repo.Migrations.AddSwitchContext do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :context_handover, :boolean, default: false, null: false
    end

    alter table(:runs) do
      add :provider, :string
    end

    flush()

    execute(
      "UPDATE runs SET provider = (SELECT provider FROM agents WHERE agents.id = runs.agent_id)",
      "SELECT 1"
    )
  end
end
