defmodule Roundtable.SchedulerTest do
  @moduledoc """
  Standing instructions, and the clock that runs them.

  The interesting cases are all about time: that a schedule fires once rather
  than every half minute, that a machine which was asleep at nine does not
  start the morning's work at noon, and that saving one at five past nine does
  not immediately fire the nine o'clock it just missed.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.Chat
  alias Roundtable.Chat.Run
  alias Roundtable.Scheduler

  # A Monday, the Saturday that week, and the night before both.
  @monday ~D[2026-09-14]
  @saturday ~D[2026-09-19]
  @already_ran ~U[2026-09-13 00:00:00Z]

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Checkout", "directory" => File.cwd!()})
    {:ok, ada} = Chat.create_agent(room.id, %{"name" => "ada", "provider" => "claude"})
    %{room: room, ada: ada}
  end

  defp schedule(room, agent, attrs) do
    {:ok, schedule} =
      Chat.create_schedule(
        room.id,
        Map.merge(%{"agent_id" => agent.id, "prompt" => "sweep the board"}, attrs)
      )

    # A standing instruction is older than the day it runs on; one saved a
    # millisecond ago would be younger than the occurrence under test.
    Chat.change(schedule, last_run_at: @already_ran)
  end

  # The two clocks the scheduler is handed, as a consistent pair. What the
  # scheduler uses is the distance between them, so a fabricated day with no
  # offset says the same thing here as a real one does on any machine.
  defp at(date, time) do
    local = NaiveDateTime.new!(date, time)
    {local, DateTime.from_naive!(local, "Etc/UTC")}
  end

  defp wake({local, utc}), do: Scheduler.wake(local, utc)

  defp said(room), do: room.id |> Chat.messages() |> Enum.map(& &1.body)

  describe "waking a participant" do
    test "at the time it was asked for", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00"})

      assert [_woken] = wake(at(@monday, ~T[09:00:20]))
      assert said(room) == ["@ada sweep the board"]

      # And the mention does what a mention does: it queues a turn.
      assert [%Run{agent_id: id}] = Repo.all(Run)
      assert id == ada.id
    end

    test "and not a minute before it", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00"})

      assert wake(at(@monday, ~T[08:59:40])) == []
      assert said(room) == []
    end

    test "once, however often the clock is looked at", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00"})

      wake(at(@monday, ~T[09:00:10]))
      wake(at(@monday, ~T[09:00:40]))
      wake(at(@monday, ~T[09:04:00]))

      assert length(said(room)) == 1
    end

    test "twice a day, when that is what was asked for", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00,17:30"})

      wake(at(@monday, ~T[09:00:10]))
      wake(at(@monday, ~T[17:30:10]))

      assert length(said(room)) == 2
    end

    test "on the days it runs on, and no others", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00", "days" => "1,2,3,4,5"})

      assert wake(at(@saturday, ~T[09:00:10])) == []
      assert [_woken] = wake(at(@monday, ~T[09:00:10]))
    end
  end

  describe "time that has already passed" do
    test "a morning missed is not delivered at noon", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00"})

      assert wake(at(@monday, ~T[12:00:00])) == []
      assert said(room) == []
    end

    test "but a restart a few minutes late still runs it", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00"})

      assert [_woken] = wake(at(@monday, ~T[09:06:00]))
    end

    test "last thing at night is not repeated after midnight", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "23:55"})

      wake(at(@monday, ~T[23:55:10]))
      wake(at(Date.add(@monday, 1), ~T[00:02:00]))

      assert length(said(room)) == 1
    end

    test "a schedule saved just after its time waits for the next one", %{room: room, ada: ada} do
      # In real time, not a fabricated day: what is being tested is that the
      # instruction is younger than the occurrence it would otherwise pick up.
      now = NaiveDateTime.local_now()
      six_minutes_ago = NaiveDateTime.add(now, -6 * 60, :second)
      at = Calendar.strftime(six_minutes_ago, "%H:%M")

      {:ok, _} =
        Chat.create_schedule(room.id, %{
          "agent_id" => ada.id,
          "prompt" => "sweep the board",
          "at" => at
        })

      assert Scheduler.wake(now, DateTime.utc_now()) == []
      assert said(room) == []
    end
  end

  describe "schedules that should say nothing" do
    test "one that is switched off", %{room: room, ada: ada} do
      room
      |> schedule(ada, %{"at" => "09:00"})
      |> Map.get(:id)
      |> then(&Chat.update_schedule(&1, %{"enabled" => false}))

      assert wake(at(@monday, ~T[09:00:10])) == []
      assert said(room) == []
    end

    test "one whose participant has left the room", %{room: room, ada: ada} do
      schedule(room, ada, %{"at" => "09:00"})
      {:ok, _} = Chat.delete_agent(ada.id)

      assert Chat.schedules() == []
      assert wake(at(@monday, ~T[09:00:10])) == []
    end
  end

  describe "what a schedule is" do
    test "times are read the way they were meant, and sorted", %{room: room, ada: ada} do
      assert %{at: "09:00,17:30"} = schedule(room, ada, %{"at" => "17:30, 9"})
      assert %{at: "08:05,08:30"} = schedule(room, ada, %{"at" => "8:30 8:05"})
    end

    test "a time that is not one is refused", %{room: room, ada: ada} do
      assert {:error, changeset} =
               Chat.create_schedule(room.id, %{
                 "agent_id" => ada.id,
                 "prompt" => "sweep",
                 "at" => "half past nine"
               })

      assert "needs a time of day, like 09:00 or 09:00,17:30" in errors_on(changeset).at
    end

    test "more times than anyone means is refused", %{room: room, ada: ada} do
      every_five = Enum.map_join(0..23, ",", &"#{&1}:00")

      assert {:error, changeset} =
               Chat.create_schedule(room.id, %{
                 "agent_id" => ada.id,
                 "prompt" => "sweep",
                 "at" => every_five
               })

      assert "can have at most 12 times of day" in errors_on(changeset).at
    end

    test "somebody from another room is refused", %{room: room, ada: ada} do
      {:ok, other} = Chat.create_room(%{"name" => "Billing", "directory" => File.cwd!()})

      assert {:error, changeset} =
               Chat.create_schedule(other.id, %{
                 "agent_id" => ada.id,
                 "prompt" => "sweep",
                 "at" => "09:00"
               })

      assert "is not a participant in this room" in errors_on(changeset).agent_id
      assert Chat.schedules(room.id) == []
    end

    test "it reads back as a person would say it", %{room: room, ada: ada} do
      alias Roundtable.Chat.Schedule

      assert Schedule.describe(schedule(room, ada, %{"at" => "09:00"})) == "09:00 every day"

      assert Schedule.describe(schedule(room, ada, %{"at" => "09:00", "days" => "1,2,3,4,5"})) ==
               "09:00 on weekdays"

      assert Schedule.describe(schedule(room, ada, %{"at" => "09:00,17:30", "days" => "3"})) ==
               "09:00, 17:30 on Wed"
    end
  end
end
