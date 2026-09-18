defmodule Roundtable.Repo.Migrations.RememberWhatARoomHasLearned do
  use Ecto.Migration

  @moduledoc """
  What a room has learned: the facts every participant should start a turn with.

  Separate from the room's brief on purpose. The brief is what the human meant
  this team to do, authored once and edited deliberately; these are the things
  the room found out along the way, and they accumulate. Keeping them apart is
  what lets notes be added, superseded and dropped without anyone rewriting the
  statement of intent underneath.

  `kind` decides whether a note reaches a participant at all: conventions,
  decisions and gotchas do, scratch does not. `pinned` decides what survives
  when there are more notes than a prompt can afford to carry. `run_id` records
  which turn a note came out of, so a wrong one can be traced back rather than
  argued with.
  """

  def change do
    create table(:room_notes) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      # Not a foreign key: a note outlives the turn it came from, and deleting
      # a participant should not quietly delete what the room learned from it.
      add :run_id, :integer
      add :body, :text, null: false
      add :kind, :string, null: false, default: "convention"
      add :author, :string, null: false, default: ""
      add :pinned, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create index(:room_notes, [:room_id])
  end
end
