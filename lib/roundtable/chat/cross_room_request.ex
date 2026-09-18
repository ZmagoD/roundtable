defmodule Roundtable.Chat.CrossRoomRequest do
  @moduledoc """
  One room asking another for something.

  Rooms are otherwise sealed: an agent sees only its own room's roster and
  history. This record is the single seam between two of them, and it exists so
  an answer can find its way home — without it, a reply would land only in the
  answering room's transcript, where nobody who asked is looking.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(ask delegate)
  @statuses ~w(pending_approval delivered answered declined failed)

  schema "cross_room_requests" do
    field :kind, :string
    field :status, :string, default: "delivered"
    field :body, :string
    field :answer, :string
    field :error, :string
    field :depth, :integer, default: 0

    belongs_to :from_room, Roundtable.Chat.Room
    belongs_to :from_message, Roundtable.Chat.Message
    belongs_to :from_agent, Roundtable.Chat.Agent

    belongs_to :to_room, Roundtable.Chat.Room
    belongs_to :to_agent, Roundtable.Chat.Agent
    belongs_to :to_message, Roundtable.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :kind,
      :status,
      :body,
      :answer,
      :error,
      :depth,
      :from_room_id,
      :from_message_id,
      :from_agent_id,
      :to_room_id,
      :to_agent_id,
      :to_message_id
    ])
    |> validate_required([
      :kind,
      :body,
      :from_room_id,
      :from_message_id,
      :to_room_id,
      :to_agent_id
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
  end

  def kinds, do: @kinds
end
