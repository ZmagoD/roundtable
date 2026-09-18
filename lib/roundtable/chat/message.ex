defmodule Roundtable.Chat.Message do
  use Ecto.Schema

  schema "messages" do
    belongs_to :room, Roundtable.Chat.Room
    belongs_to :agent, Roundtable.Chat.Agent
    field :sender, :string
    field :body, :string
    field :metadata, :map, default: %{}
    field :kind, :string, default: "human"
    field :depth, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
