defmodule Roundtable.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  @moduledoc """
  The layer above a room: one organization per project.

  Rooms are teams — engineering, marketing, sales — and a person runs more than
  one project at a time. Without something above them, every team from every
  project shares one flat list and one name space.
  """

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:name])
  end
end
