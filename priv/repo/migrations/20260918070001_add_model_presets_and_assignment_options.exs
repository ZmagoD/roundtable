defmodule Roundtable.Repo.Migrations.AddModelPresetsAndAssignmentOptions do
  use Ecto.Migration

  def change do
    create table(:model_presets) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :cost_tier, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:model_presets, [:provider, :name])

    alter table(:agents) do
      add :session_model, :string
      add :cost_tier, :string, default: "unknown", null: false
    end

    alter table(:messages) do
      add :metadata, :map, default: %{}, null: false
    end

    alter table(:runs) do
      add :model, :string
      add :cost_tier, :string, default: "unknown", null: false
      add :purpose, :string, default: "general", null: false
    end
  end
end
