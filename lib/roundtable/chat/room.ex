defmodule Roundtable.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :name, :string
    field :directory, :string
    # The room's shared brief: what this team is doing and how it works.
    field :context, :string, default: ""
    belongs_to :organization, Roundtable.Chat.Organization
    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :directory, :context, :organization_id])
    |> validate_required([:name, :directory, :organization_id])
    |> validate_length(:name, max: 80)
    |> validate_length(:context, max: 4000)
    |> validate_length(:directory, max: 4096)
  end
end
