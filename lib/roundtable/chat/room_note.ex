defmodule Roundtable.Chat.RoomNote do
  @moduledoc """
  One thing this room has learned, in a line a participant can act on.

  Short on purpose. A note earns its place by changing what someone would
  otherwise do — where a thing lives, which way was already tried, what not to
  touch — and every note costs the same prompt space on every turn from now on.
  Anything longer than a couple of sentences belongs in the room's brief, or in
  the conversation.

  `kind` is the difference between a fact worth carrying and a jotting: only
  conventions, decisions and gotchas reach a participant, and `scratch` is
  there so that writing something down does not oblige anyone to read it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Kinds that reach a participant, in the order a reader wants them: how this
  # room works, then what it settled, then what bit someone.
  @carried ~w(convention decision gotcha)
  @kinds @carried ++ ~w(scratch)

  schema "room_notes" do
    belongs_to :room, Roundtable.Chat.Room
    field :run_id, :integer
    field :body, :string
    field :kind, :string, default: "convention"
    field :author, :string, default: ""
    field :pinned, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  @doc "The kinds a note can have, and the ones a participant is told about."
  def kinds, do: @kinds
  def carried, do: @carried

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:body, :kind, :author, :pinned, :run_id])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:room_id, :body])
    |> validate_length(:body, max: 500)
    |> validate_length(:author, max: 80)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:room_id)
  end
end
