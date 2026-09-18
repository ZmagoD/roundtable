defmodule Roundtable.Scheduler do
  @moduledoc """
  Runs a room's standing instructions.

  Wakes twice a minute, looks at what fell due since it last looked, and says
  it. What it posts is an ordinary message with an ordinary mention, so the
  queue, the approvals and the retries that follow are the same ones that
  follow anything the human types.

  An occurrence is only picked up for a few minutes after it was due. A machine
  asleep at nine should not start the morning's work at noon, when whoever
  asked for it has moved on to something else.
  """
  use GenServer
  require Logger

  alias Roundtable.{Chat, Coordinator}
  alias Roundtable.Chat.Schedule

  @tick :timer.seconds(30)

  # How late an occurrence may be picked up. Long enough to survive a restart
  # or a laptop lid, short enough that nothing arrives out of its day.
  @catch_up 10 * 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:roundtable, :start_agents, true),
      do: :timer.send_interval(@tick, self(), :tick)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    wake()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Posts everything that came due, and returns the schedules that ran.

  Takes the current time rather than reading it, because a schedule is a thing
  about clocks and a test should be able to say which hour it is.
  """
  def wake(now_local \\ NaiveDateTime.local_now(), now_utc \\ DateTime.utc_now()) do
    for schedule <- Chat.schedules(),
        schedule.enabled,
        {:ok, at} <- [due(schedule, now_local, now_utc)] do
      run(schedule, at)
      schedule
    end
  end

  # Recorded before posting: a schedule that fails to post costs the room one
  # missed instruction, while one that posts twice costs it a turn it pays for
  # twice and a second agent working on the same thing.
  defp run(schedule, at) do
    agent = Chat.agent!(schedule.agent_id)
    Chat.schedule_ran(schedule, at)
    Coordinator.post(schedule.room_id, "@#{agent.name} #{schedule.prompt}", sender: "schedule")
  rescue
    error ->
      Logger.error("Schedule #{schedule.id} did not run: #{Exception.message(error)}")
      :error
  end

  defp due(schedule, now_local, now_utc) do
    since = schedule.last_run_at || schedule.inserted_at

    schedule
    |> occurrences(now_local)
    |> Enum.map(&as_utc(&1, now_local, now_utc))
    |> Enum.filter(&(DateTime.compare(&1, since) == :gt))
    |> Enum.max(DateTime, fn -> nil end)
    |> case do
      nil -> :not_due
      at -> {:ok, at}
    end
  end

  # Yesterday as well as today: at ten past midnight, the day's last occurrence
  # was on the date before this one.
  defp occurrences(schedule, now_local) do
    days = Schedule.days(schedule)
    today = NaiveDateTime.to_date(now_local)

    [0, -1]
    |> Enum.map(&Date.add(today, &1))
    |> Enum.filter(&(days == [] or Date.day_of_week(&1) in days))
    |> Enum.flat_map(fn date ->
      Enum.map(Schedule.times(schedule), fn {hour, minute} ->
        NaiveDateTime.new!(date, Time.new!(hour, minute, 0))
      end)
    end)
    |> Enum.filter(&recently_due?(&1, now_local))
  end

  defp recently_due?(occurrence, now_local) do
    late = NaiveDateTime.diff(now_local, occurrence)
    late >= 0 and late <= @catch_up
  end

  # The same instant, expressed the way the database keeps it. Derived from the
  # two clocks we were handed rather than from a timezone database, which this
  # app does not carry and would only need for this one subtraction.
  defp as_utc(occurrence, now_local, now_utc) do
    now_utc
    |> DateTime.add(NaiveDateTime.diff(occurrence, now_local), :second)
    |> DateTime.truncate(:second)
  end
end
