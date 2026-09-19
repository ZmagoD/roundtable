defmodule Roundtable.Repo.Migrations.GiveAnOrganizationAFolderAndBrief do
  use Ecto.Migration

  @moduledoc """
  What a project holds besides its teams: where its work lives, and what the
  whole project is doing.

  The folder is nullable because a project does not have to be a checkout —
  marketing and sales are organizations too — and because teams that already
  exist keep the folder they were made with. Nothing is inferred from them: two
  rooms in "Existing workspace" may point at entirely different trees, and
  guessing one folder for the project would move work somewhere it never was.
  """

  def change do
    alter table(:organizations) do
      add :directory, :string
      add :context, :text, default: "", null: false
    end
  end
end
