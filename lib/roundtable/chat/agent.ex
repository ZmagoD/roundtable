defmodule Roundtable.Chat.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "agents" do
    belongs_to :room, Roundtable.Chat.Room
    field :name, :string
    field :provider, :string
    field :role, :string, default: ""
    field :model, :string
    field :cost_tier, :string, default: "unknown"
    field :directory, :string
    field :session_id, :string
    field :session_model, :string
    field :last_seen_id, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  @doc """
  The fields that can change after a participant exists.

  Deliberately not provider or directory: see `Roundtable.Chat.update_agent/2`.
  """
  def rename_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :role, :model, :cost_tier])
    |> update_change(:name, &String.downcase/1)
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]{0,29}$/)
    |> validate_exclusion(:name, ["you", "system", "all"])
    |> validate_length(:role, max: 4000)
    |> validate_inclusion(:cost_tier, ["economy", "standard", "premium", "unknown"])
    |> unique_constraint(:name,
      name: :agents_room_id_name_index,
      message: "is already used in this room"
    )
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :provider, :role, :model, :directory, :cost_tier])
    |> update_change(:name, &String.downcase/1)
    |> validate_required([:room_id, :name, :provider, :directory])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]{0,29}$/)
    |> validate_exclusion(:name, ["you", "system", "all"])
    |> validate_inclusion(:provider, Roundtable.Agents.ids())
    |> validate_length(:role, max: 4000)
    |> validate_inclusion(:cost_tier, ["economy", "standard", "premium", "unknown"])
    # Reported against :name, not the index's first column: "room_id has
    # already been taken" means nothing to someone naming a participant.
    |> unique_constraint(:name,
      name: :agents_room_id_name_index,
      message: "is already used in this room"
    )
    |> foreign_key_constraint(:room_id)
  end
end
