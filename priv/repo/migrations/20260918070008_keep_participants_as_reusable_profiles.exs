defmodule Roundtable.Repo.Migrations.KeepParticipantsAsReusableProfiles do
  use Ecto.Migration

  @moduledoc """
  A library of participants, so "the reviewer" is defined once.

  Profiles are templates, not shared participants: adding one to a room creates
  a participant there. A single live agent in two rooms would mean one provider
  session resuming across two working trees and one queue serialising unrelated
  work.
  """

  def change do
    create table(:agent_profiles) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :model, :string
      add :cost_tier, :string, null: false, default: "unknown"
      add :role, :text, null: false, default: ""
      add :auto_approve, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_profiles, [:name])
  end
end
