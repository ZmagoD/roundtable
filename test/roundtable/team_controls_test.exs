defmodule Roundtable.TeamControlsTest do
  @moduledoc """
  The team-level controls the organization plan asks for: when a schedule will
  next run, pausing a team's schedules without stopping its work, and the
  instruction layers a participant works to.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.Chat
  alias Roundtable.Chat.Schedule

  # A Monday morning, local time.
  @monday_morning ~N[2026-09-14 08:30:00]

  setup do
    {:ok, organization} =
      Chat.create_organization(%{"name" => "Acme", "context" => "Ship the billing service."})

    {:ok, room} =
      Chat.create_room(%{
        "name" => "Engineering",
        "directory" => File.cwd!(),
        "organization_id" => organization.id,
        "context" => "Tests with every change."
      })

    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    %{organization: organization, room: room, ada: ada}
  end

  describe "next run" do
    test "is later today when a time is still ahead" do
      schedule = %Schedule{at: "09:00,17:30", days: "", enabled: true}
      assert Schedule.next_run(schedule, @monday_morning) == ~N[2026-09-14 09:00:00]
    end

    test "is not the occurrence due this very minute" do
      schedule = %Schedule{at: "08:30", days: "", enabled: true}
      assert Schedule.next_run(schedule, @monday_morning) == ~N[2026-09-15 08:30:00]
    end

    test "skips days the schedule does not run on" do
      weekends = %Schedule{at: "10:00", days: "6,7", enabled: true}
      assert Schedule.next_run(weekends, @monday_morning) == ~N[2026-09-19 10:00:00]
    end

    test "finds next week's when this week's only time has passed" do
      mondays = %Schedule{at: "08:00", days: "1", enabled: true}
      assert Schedule.next_run(mondays, @monday_morning) == ~N[2026-09-21 08:00:00]
    end

    test "is nothing while the schedule is off or has no time" do
      assert Schedule.next_run(%Schedule{at: "09:00", days: "", enabled: false}) == nil
      assert Schedule.next_run(%Schedule{at: nil, days: "", enabled: true}) == nil
    end

    test "a form's values preview the same way a saved schedule reads" do
      preview = Schedule.preview(%{"at" => "9, 17:30", "days" => "", "enabled" => "true"})

      assert Schedule.describe_next_run(preview, @monday_morning) ==
               "Mon 14 Sep at 09:00, this machine's time"
    end
  end

  test "pausing a team's schedules switches off only that team's", %{ada: ada, room: room} do
    {:ok, other_room} = Chat.create_room(%{"name" => "Other", "directory" => File.cwd!()})
    {:ok, grace} = Chat.create_agent(other_room.id, %{"name" => "grace", "provider" => "claude"})

    {:ok, mine} =
      Chat.create_schedule(room.id, %{"agent_id" => ada.id, "prompt" => "sweep", "at" => "9"})

    {:ok, theirs} =
      Chat.create_schedule(other_room.id, %{
        "agent_id" => grace.id,
        "prompt" => "sweep",
        "at" => "9"
      })

    assert Chat.pause_schedules(room.id) == 1
    refute Chat.schedule!(mine.id).enabled
    assert Chat.schedule!(theirs.id).enabled
    assert Chat.pause_schedules(room.id) == 0
  end

  describe "instruction layers" do
    test "carry the organization's brief and the team's", %{room: room} do
      assert Chat.instruction_layers(room) == %{
               organization: "Acme",
               organization_brief: "Ship the billing service.",
               team_brief: "Tests with every change."
             }
    end

    test "say a layer is missing rather than passing on blank text", %{organization: org} do
      {:ok, _} = Chat.update_organization(org.id, %{"context" => "   "})

      {:ok, room} =
        Chat.create_room(%{
          "name" => "Quiet",
          "directory" => File.cwd!(),
          "organization_id" => org.id
        })

      assert %{organization_brief: nil, team_brief: nil} = Chat.instruction_layers(room)
    end

    test "are what the prompt gives a participant", %{ada: ada, room: room} do
      {:ok, _message} = Chat.post(room.id, "@ada go", kind: "human", sender: "human")
      [run] = Chat.runs(room.id)

      {prompt, _} = Chat.prompt(Chat.agent!(ada.id), run)

      assert prompt =~ "Project: Acme. The whole project is working on: Ship the billing service."
      assert prompt =~ "What this room is working on, and how: Tests with every change."
    end
  end
end
