defmodule Roundtable.Repo.Migrations.CreateChat do
  use Ecto.Migration

  def change do
    create table(:rooms) do
      add :name, :string, null: false
      add :directory, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:agents) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :provider, :string, null: false
      add :role, :text, default: ""
      add :model, :string
      add :directory, :text, null: false
      add :session_id, :string
      add :last_seen_id, :integer, default: 0, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agents, [:room_id, :name])

    create table(:messages) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :sender, :string, null: false
      add :body, :text, null: false
      add :kind, :string, default: "human", null: false
      add :depth, :integer, default: 0, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:room_id, :id])

    create table(:runs) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :status, :string, default: "queued", null: false
      add :output, :text, default: "", null: false
      add :error, :text
      add :context_until_id, :integer
      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:agent_id, :status])
    create unique_index(:runs, [:agent_id, :message_id])
  end
end
