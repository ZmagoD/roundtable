defmodule Roundtable.Chat.ModelPreset do
  use Ecto.Schema
  import Ecto.Changeset

  schema "model_presets" do
    field :name, :string
    field :provider, :string
    field :model, :string
    field :cost_tier, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(preset, attrs) do
    preset
    |> cast(attrs, [:name, :provider, :model, :cost_tier])
    |> validate_required([:name, :provider, :model, :cost_tier])
    |> validate_length(:name, max: 60)
    |> validate_length(:model, max: 200)
    |> validate_inclusion(:provider, Roundtable.Agents.ids())
    |> validate_inclusion(:cost_tier, ["economy", "standard", "premium", "unknown"])
    |> unique_constraint([:provider, :name])
  end
end
