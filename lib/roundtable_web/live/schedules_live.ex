defmodule RoundtableWeb.SchedulesLive do
  use RoundtableWeb, :live_view

  alias Roundtable.Chat

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")

    {:ok,
     socket
     |> assign(
       page_title: "Schedules",
       schedules: Chat.schedules_with_context(),
       rooms: Chat.rooms(),
       agents: Chat.agents(),
       schedule_modal: false,
       editing_id: nil,
       form_error: nil,
       schedule_form: schedule_form(Chat.agents())
     )}
  end

  @impl true
  def handle_info(:rooms_updated, socket), do: {:noreply, refresh(socket)}
  def handle_info({:room_updated, _}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("new-schedule", _params, socket) do
    {:noreply,
     assign(socket,
       editing_id: nil,
       schedule_modal: true,
       form_error: nil,
       schedule_form: schedule_form(socket.assigns.agents)
     )}
  end

  def handle_event("edit-schedule", %{"id" => id}, socket) do
    schedule = Chat.schedule!(String.to_integer(id))

    {:noreply,
     assign(socket,
       editing_id: schedule.id,
       schedule_modal: true,
       form_error: nil,
       schedule_form: to_form(schedule_attrs(schedule), as: :schedule)
     )}
  end

  def handle_event("save-schedule", %{"schedule" => attrs}, socket) do
    result =
      case socket.assigns.editing_id do
        nil ->
          agent = Chat.agent!(String.to_integer(attrs["agent_id"]))
          Chat.create_schedule(agent.room_id, attrs)

        id ->
          Chat.update_schedule(id, attrs)
      end

    case result do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> assign(editing_id: nil, schedule_modal: false, form_error: nil)
         |> refresh()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form_error: errors(changeset),
           schedule_form: to_form(attrs, as: :schedule)
         )}
    end
  rescue
    ArgumentError -> {:noreply, assign(socket, form_error: "Choose a participant.")}
  end

  def handle_event("toggle-schedule", %{"id" => id}, socket) do
    schedule = Chat.schedule!(String.to_integer(id))
    {:ok, _} = Chat.update_schedule(schedule.id, %{"enabled" => !schedule.enabled})
    {:noreply, refresh(socket)}
  end

  def handle_event("delete-schedule", %{"id" => id}, socket) do
    Chat.delete_schedule(String.to_integer(id))
    {:noreply, socket |> assign(editing_id: nil, schedule_modal: false) |> refresh()}
  end

  def handle_event("close-schedule-modal", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, schedule_modal: false, form_error: nil)}
  end

  defp refresh(socket) do
    assign(socket,
      schedules: Chat.schedules_with_context(),
      rooms: Chat.rooms(),
      agents: Chat.agents()
    )
  end

  defp schedule_form([]),
    do: to_form(%{"at" => "09:00", "days" => "", "enabled" => "true"}, as: :schedule)

  defp schedule_form(agents) do
    to_form(
      %{
        "agent_id" => to_string(hd(agents).id),
        "name" => "Daily check-in",
        "at" => "09:00",
        "days" => "",
        "enabled" => "true"
      },
      as: :schedule
    )
  end

  defp schedule_attrs(schedule) do
    %{
      "agent_id" => to_string(schedule.agent_id),
      "name" => schedule.name,
      "prompt" => schedule.prompt,
      "at" => schedule.at,
      "days" => schedule.days,
      "enabled" => to_string(schedule.enabled)
    }
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp days_options(value) do
    known = [{"Every day", ""}, {"Weekdays", "1,2,3,4,5"}, {"Weekends", "6,7"}]

    if is_binary(value) and value != "" and value not in Enum.map(known, &elem(&1, 1)),
      do: known ++ [{"Days chosen earlier", value}],
      else: known
  end

  def room_name(rooms, id),
    do: (Enum.find(rooms, &(&1.id == id)) || %{name: "Unknown room"}).name

  def last_run(nil), do: "never"
  def last_run(value), do: Calendar.strftime(value, "%d %b %Y at %H:%M")
end
