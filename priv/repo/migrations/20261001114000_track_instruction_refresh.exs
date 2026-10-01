defmodule Roundtable.Repo.Migrations.TrackInstructionRefresh do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :instruction_turns, :integer, default: 20, null: false
    end
  end
end
