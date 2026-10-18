defmodule Roundtable.Chat.TaskClosure do
  @moduledoc "Completion audit survives task room deletion and interrupted cleanup."
  use Ecto.Schema

  schema "task_closures" do
    field :task_room_id, :integer
    field :parent_room_id, :integer
    field :summary, :map
    field :status, :string, default: "sealed"
    field :error, :string
    timestamps(type: :utc_datetime)
  end
end
