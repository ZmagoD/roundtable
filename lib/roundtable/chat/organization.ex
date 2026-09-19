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
    # Where the project's work lives, when the project is a checkout at all.
    field :directory, :string
    # What the whole project is doing. A team's own brief adds to this rather
    # than replacing it.
    field :context, :string, default: ""
    has_many :rooms, Roundtable.Chat.Room
    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :directory, :context])
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_length(:directory, max: 4096)
    |> validate_length(:context, max: 4000)
    |> unique_constraint(:name)
  end
end
