defmodule Roundtable.Repo.Migrations.AddRoomWorkDocument do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :work_document, :text, null: false, default: ""
      add :work_revision, :integer, null: false, default: 0
    end
  end
end
