defmodule Roundtable.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :name, :string
    field :directory, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :directory])
    |> validate_required([:name, :directory])
    |> validate_length(:name, max: 80)
  end
end
