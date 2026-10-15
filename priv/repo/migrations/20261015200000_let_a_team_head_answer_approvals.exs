defmodule Roundtable.Repo.Migrations.LetATeamHeadAnswerApprovals do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :head_answers_approvals, :boolean, default: false, null: false
    end
  end
end
