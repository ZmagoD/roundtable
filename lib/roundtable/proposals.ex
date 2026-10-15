defmodule Roundtable.Proposals do
  @moduledoc """
  Changes a participant asked for that only the human can make.

  Some changes to a team are the human's to make: adding a participant whose
  provider cannot stop and ask before a tool runs, choosing who leads, and
  removing someone. Room tools propose these instead of refusing them, and the
  human answers on a card in the conversation. Accepting does exactly what the
  browser's own controls do, so the card is a shortcut to the form, not a
  second set of rules.
  """
  alias Roundtable.{Chat, Coordinator}

  @doc """
  Carries a pending proposal out and marks it accepted.

  A proposal that can no longer be carried out — its participant already
  gone, its name taken since — stays pending with the reason returned, so the
  human can clear the way and accept it again, or dismiss it.
  """
  def accept(message_id) do
    message = Chat.proposal!(message_id)

    with :ok <- pending(message),
         {:ok, note} <- carry_out(message.metadata["proposal"], message.metadata["params"]) do
      Chat.resolve_proposal(message, "accepted", note)
    end
  end

  def dismiss(message_id) do
    message = Chat.proposal!(message_id)

    with :ok <- pending(message),
         do: Chat.resolve_proposal(message, "dismissed")
  end

  defp pending(%{metadata: %{"status" => "pending"}}), do: :ok
  defp pending(_message), do: {:error, "This request has already been answered."}

  # Approval stays off whatever the profile says: the human can switch it on
  # from the participant's card, but a click on someone else's request should
  # not grant it in passing.
  defp carry_out("add_participant", %{"room_id" => room_id, "profile_id" => profile_id} = params) do
    with :ok <- room_exists(room_id),
         :ok <- profile_exists(profile_id),
         {:ok, agent} <-
           Chat.add_profile_to_room(room_id, profile_id, params["name"], auto_approve: false)
           |> explain(),
         do: {:ok, "#{agent.name} joined."}
  end

  defp carry_out("add_participant", %{"room_id" => room_id, "attrs" => attrs}) do
    with :ok <- room_exists(room_id),
         {:ok, agent} <-
           Chat.create_agent(room_id, Map.put(attrs, "auto_approve", false)) |> explain(),
         do: {:ok, "#{agent.name} joined."}
  end

  defp carry_out("set_team_head", %{"agent_id" => agent_id}) do
    with {:ok, agent} <- still_here(agent_id),
         {:ok, head} <- Chat.set_team_head(agent.id),
         do: {:ok, "#{head.name} is the team head."}
  end

  defp carry_out("remove_participant", %{"agent_id" => agent_id}) do
    with {:ok, agent} <- still_here(agent_id) do
      case Coordinator.remove_agent(agent.id) do
        {:ok, _} -> {:ok, "#{agent.name} was removed. What it said stays in the room."}
        {:error, _} -> {:error, "Could not remove #{agent.name}."}
      end
    end
  end

  defp room_exists(room_id) do
    if Enum.any?(Chat.rooms(), &(&1.id == room_id)),
      do: :ok,
      else: {:error, "That room no longer exists."}
  end

  defp profile_exists(profile_id) do
    if Enum.any?(Chat.agent_profiles(), &(&1.id == profile_id)),
      do: :ok,
      else: {:error, "That profile has been deleted."}
  end

  defp still_here(agent_id) do
    case Chat.agent(agent_id) do
      nil -> {:error, "That participant is no longer in the room."}
      agent -> {:ok, agent}
    end
  end

  defp explain({:ok, record}), do: {:ok, record}

  defp explain({:error, changeset}) do
    reason =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)

    {:error, "Could not add it: #{reason}."}
  end
end
