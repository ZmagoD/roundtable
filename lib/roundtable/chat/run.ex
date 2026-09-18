defmodule Roundtable.Chat.Run do
  use Ecto.Schema

  schema "runs" do
    belongs_to :agent, Roundtable.Chat.Agent
    belongs_to :message, Roundtable.Chat.Message
    field :model, :string
    field :cost_tier, :string, default: "unknown"
    field :purpose, :string, default: "general"
    field :status, :string, default: "queued"
    field :output, :string, default: ""
    field :error, :string
    field :context_until_id, :integer
    timestamps(type: :utc_datetime)
  end
end
