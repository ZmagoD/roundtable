defmodule Roundtable.Repo.Migrations.AddQuotaRetryState do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :auto_retry, :boolean, null: false, default: false
    end

    alter table(:runs) do
      add :retry_at, :utc_datetime
      add :retry_count, :integer, null: false, default: 0
      add :retry_context, :text, null: false, default: ""
    end

    create index(:runs, [:status, :retry_at])
  end
end
