defmodule Roundtable.Repo.Migrations.AddSupervisedRetries do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :supervised_retries, :integer, null: false, default: 0
    end
  end
end
