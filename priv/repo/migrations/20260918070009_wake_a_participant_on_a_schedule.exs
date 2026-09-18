defmodule Roundtable.Repo.Migrations.WakeAParticipantOnASchedule do
  use Ecto.Migration

  @moduledoc """
  Standing instructions: what to say, to whom, and at which times of day.

  Times of day rather than a cron expression. What a room actually wants is
  "every morning" and "twice a day", and a schedule that can be read at a
  glance is worth more than one that can express the third Tuesday in March.

  A schedule belongs to a participant as much as to a room: when either goes,
  so does the standing instruction to wake it.
  """

  def change do
    create table(:schedules) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :prompt, :text, null: false
      add :at, :string, null: false
      add :days, :string, null: false, default: ""
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:schedules, [:room_id])
    create index(:schedules, [:agent_id])
  end
end
