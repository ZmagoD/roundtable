defmodule Roundtable.Repo.Migrations.CreateCrossRoomRequests do
  use Ecto.Migration

  def change do
    create table(:cross_room_requests) do
      add :kind, :string, null: false
      add :status, :string, default: "queued", null: false
      add :body, :text, null: false
      add :answer, :text
      add :error, :string
      # Inherited from the asking message so one four-hop cap covers a chain
      # that crosses rooms.
      add :depth, :integer, default: 0, null: false

      add :from_room_id, references(:rooms, on_delete: :delete_all), null: false
      add :from_message_id, references(:messages, on_delete: :delete_all), null: false
      add :from_agent_id, references(:agents, on_delete: :nilify_all)

      add :to_room_id, references(:rooms, on_delete: :delete_all), null: false
      add :to_agent_id, references(:agents, on_delete: :delete_all), null: false
      # The message this request became in the target room. Its run's completion
      # is what carries the answer home.
      add :to_message_id, references(:messages, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:cross_room_requests, [:to_message_id])
    create index(:cross_room_requests, [:from_room_id, :status])
  end
end
