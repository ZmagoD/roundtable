defmodule Roundtable.Repo.Migrations.RememberWhetherARunPinnedItsModel do
  use Ecto.Migration

  @moduledoc """
  Tells a run's own model apart from the one its participant happened to have.

  Without it, a queued or retried turn keeps whatever model it was created
  with, so changing a participant's model appears to do nothing. Existing rows
  are unpinned: they took the participant's default, which is what they should
  pick up again.
  """

  def change do
    alter table(:runs) do
      add :model_pinned, :boolean, default: false, null: false
    end
  end
end
