defmodule Roundtable.Repo.Migrations.AddUsageTracking do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :token_usage, :map, null: false, default: %{}
    end

    create table(:provider_usage, primary_key: false) do
      add :provider, :string, primary_key: true
      add :data, :map, null: false, default: %{}
      add :recorded_at, :utc_datetime_usec, null: false
    end
  end
end
