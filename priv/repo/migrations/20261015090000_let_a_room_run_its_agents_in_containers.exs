defmodule Roundtable.Repo.Migrations.LetARoomRunItsAgentsInContainers do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :sandbox, :boolean, null: false, default: false
      add :sandbox_packages, :string, null: false, default: ""
    end
  end
end
