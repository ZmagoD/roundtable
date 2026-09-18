defmodule Roundtable.Chat.AgentProfile do
  @moduledoc """
  A participant worth having again: provider, model, cost tier, role, approvals.

  A template rather than a participant. Adding one to a room creates an agent
  there, with its own session and its own queue, because a room is a working
  tree and a session belongs to one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "agent_profiles" do
    field :name, :string
    field :provider, :string
    field :model, :string
    field :cost_tier, :string, default: "unknown"
    field :role, :string, default: ""
    field :auto_approve, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, ~w(name provider model cost_tier role auto_approve)a)
    |> update_change(:name, &String.downcase/1)
    |> validate_required([:name, :provider])
    # The name is used as the participant's name in a room, so it follows the
    # same rule rather than producing an invalid agent later.
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]{0,29}$/)
    |> validate_exclusion(:name, ["you", "system", "all"])
    |> validate_inclusion(:provider, Roundtable.Agents.ids())
    |> validate_inclusion(:cost_tier, ["economy", "standard", "premium", "unknown"])
    |> validate_length(:role, max: 4000)
    |> unique_constraint(:name, message: "is already a profile")
  end
end
