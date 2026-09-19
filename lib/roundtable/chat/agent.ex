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
    field :auto_approve, :boolean, default: false
    # The one participant in this team the human talks to, who hands work to
    # the rest. Set through Chat.set_team_head/1, never cast from a form.
    field :head, :boolean, default: false
    field :directory, :string
    field :session_id, :string
    field :session_model, :string
    # The role the provider session was started under, so a turn can tell the
    # participant when its brief has changed underneath an open session.
    field :session_role, :string
    field :last_seen_id, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  @doc """
  The fields that can change after a participant exists.

  Directory stays fixed to the room. Provider can change after creation so a
  human can move a participant to another account when a provider runs out.
  """
  def rename_changeset(agent, attrs, renamable? \\ true) do
    agent
    |> cast(
      attrs,
      if(renamable?,
        do: ~w(name provider role model cost_tier auto_approve)a,
        else: ~w(provider role model cost_tier auto_approve)a
      )
    )
    |> update_change(:name, &String.downcase/1)
    |> validate_required([:name])
    |> refuse_rename(renamable?, attrs)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]{0,29}$/)
    |> validate_exclusion(:name, ["you", "system", "all", "schedule"])
    |> validate_length(:role, max: 4000)
    |> validate_inclusion(:cost_tier, ["economy", "standard", "premium", "unknown"])
    |> unique_constraint(:name,
      name: :agents_room_id_name_index,
      message: "is already used in this room"
    )
  end

  # Silently ignoring a name the caller sent would be worse than refusing it.
  defp refuse_rename(changeset, true, _attrs), do: changeset

  defp refuse_rename(changeset, false, attrs) do
    asked = attrs["name"] || attrs[:name]

    if asked && String.downcase(to_string(asked)) != changeset.data.name do
      add_error(changeset, :name, "cannot change once a participant has taken a turn")
    else
      changeset
    end
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, ~w(name provider role model directory cost_tier auto_approve)a)
    |> update_change(:name, &String.downcase/1)
    |> validate_required([:room_id, :name, :provider, :directory])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]{0,29}$/)
    |> validate_exclusion(:name, ["you", "system", "all", "schedule"])
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
