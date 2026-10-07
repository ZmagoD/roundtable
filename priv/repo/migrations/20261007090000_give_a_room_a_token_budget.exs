defmodule Roundtable.Repo.Migrations.GiveARoomATokenBudget do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :token_budget, :integer
    end
  end
end
