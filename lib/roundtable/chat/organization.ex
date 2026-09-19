defmodule Roundtable.Chat.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A project, holding the teams working on it.

  Team names only have to be unique inside one of these, so two projects can
  both have an engineering team without one shadowing the other.
  """

  schema "organizations" do
    field :name, :string
    has_many :rooms, Roundtable.Chat.Room
    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:name)
  end
end
