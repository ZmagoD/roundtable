defmodule Roundtable.Chat.Schedule do
  @moduledoc """
  A standing instruction: what to say to a participant, and when.

  Times of day, not a cron expression. Rooms want "every weekday morning" and
  "twice a day", and a line anyone can read beats one that can also express the
  third Tuesday in March. `at` is a sorted list of times — "09:00,17:30" — and
  `days` is either empty, meaning every day, or the weekdays it runs on, 1 for
  Monday through 7 for Sunday.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Times of day one schedule may hold. A standing instruction is a rhythm, not
  # a loop: anything past this is a turn every few minutes, paid for every day.
  @max_times 12

  # A mention, as `Roundtable.Chat.recipients/2` reads one. The scheduler posts
  # "@name <prompt>", and the whole line is scanned for mentions — so a prompt
  # carrying its own would wake someone the schedule never named, and `@all`
  # would wake the entire room on every occurrence. The prompt says what to do;
  # who it goes to is the schedule's own field. Kept in step with the reader by
  # a test, not by sharing the pattern: see `schedule_test.exs`.
  @mention ~r/(?<![\w@])@([a-z][a-z0-9_-]*)\b(?!\/)/i

  schema "schedules" do
    belongs_to :room, Roundtable.Chat.Room
    belongs_to :agent, Roundtable.Chat.Agent
    field :name, :string, default: "Untitled schedule"
    field :prompt, :string
    field :at, :string
    field :days, :string, default: ""
    field :enabled, :boolean, default: true
    # When this last woke someone. Until it has, an occurrence only counts if
    # it is later than the schedule itself, so saving one at 09:05 does not
    # immediately fire the 09:00 it just missed.
    field :last_run_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:agent_id, :name, :prompt, :at, :days, :enabled])
    |> update_change(:name, &String.trim/1)
    |> update_change(:at, &normalise_times/1)
    |> update_change(:days, &normalise_days/1)
    |> validate_required([:room_id, :agent_id, :name, :prompt, :at])
    |> validate_length(:name, max: 120)
    |> validate_length(:prompt, max: 4000)
    |> validate_no_mentions()
    |> validate_times()
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:room_id)
  end

  @doc "The times of day this runs at, as `{hour, minute}`."
  def times(%__MODULE__{at: at}), do: at |> String.split(",", trim: true) |> Enum.map(&time/1)

  @doc "The weekdays it runs on, 1 for Monday. An empty list means every day."
  def days(%__MODULE__{days: days}),
    do: days |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)

  @doc "How a person reads it back: `09:00, 17:30 on weekdays`."
  def describe(%__MODULE__{} = schedule) do
    "#{schedule.at |> String.split(",") |> Enum.join(", ")} #{describe_days(days(schedule))}"
  end

  defp describe_days([]), do: "every day"
  defp describe_days([1, 2, 3, 4, 5]), do: "on weekdays"
  defp describe_days([6, 7]), do: "at weekends"
  defp describe_days(days), do: "on #{Enum.map_join(days, ", ", &day_name/1)}"

  defp day_name(day), do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), day - 1)

  # "9", "9:30", "09:00 17:30" and "09:00, 17:30" all mean what they look like.
  # Anything else is left alone, so the changeset can say what was wrong with it.
  defp normalise_times(at) when is_binary(at) do
    at
    |> String.split([",", " "], trim: true)
    |> Enum.map(&time/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(",", fn {hour, minute} ->
      String.pad_leading("#{hour}", 2, "0") <> ":" <> String.pad_leading("#{minute}", 2, "0")
    end)
  end

  defp normalise_times(at), do: at

  defp normalise_days(days) when is_binary(days) do
    days
    |> String.split([",", " "], trim: true)
    |> Enum.map(&Integer.parse/1)
    |> Enum.flat_map(fn
      {day, _rest} when day in 1..7 -> [day]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp normalise_days(days), do: days

  defp time(text) do
    case String.split(String.trim(text), ":") do
      [hour] -> parse(hour, "0")
      [hour, minute] -> parse(hour, minute)
      _ -> nil
    end
  end

  defp parse(hour, minute) do
    with {hour, ""} <- Integer.parse(String.trim(hour)),
         {minute, ""} <- Integer.parse(String.trim(minute)),
         true <- hour in 0..23 and minute in 0..59 do
      {hour, minute}
    else
      _ -> nil
    end
  end

  @doc "Whether text carries a mention the scheduler's post would act on."
  def mentions(text) when is_binary(text),
    do: @mention |> Regex.scan(text, capture: :all_but_first) |> List.flatten()

  def mentions(_text), do: []

  defp validate_no_mentions(changeset) do
    case changeset |> get_field(:prompt) |> mentions() do
      [] ->
        changeset

      names ->
        add_error(
          changeset,
          :prompt,
          "cannot mention #{Enum.map_join(names, ", ", &"@#{&1}")} — a schedule wakes the " <>
            "participant it names, and a mention here would wake someone else every time it runs"
        )
    end
  end

  defp validate_times(changeset) do
    case get_field(changeset, :at) do
      at when is_binary(at) and at != "" -> validate_count(changeset, at)
      _ -> add_error(changeset, :at, "needs a time of day, like 09:00 or 09:00,17:30")
    end
  end

  defp validate_count(changeset, at) do
    if length(String.split(at, ",")) > @max_times,
      do: add_error(changeset, :at, "can have at most #{@max_times} times of day"),
      else: changeset
  end
end
