defmodule Roundtable.Repo.Migrations.GiveARoomASharedBrief do
  use Ecto.Migration

  @moduledoc """
  What the room is working on, in one place instead of in every role.

  Without it, "we are on Elixir and Phoenix, run mix precommit before calling
  anything done" has to be repeated in each participant's role, where the
  copies drift apart.
  """

  def change do
    alter table(:rooms) do
      add :context, :text, default: "", null: false
    end
  end
end
