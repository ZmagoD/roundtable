defmodule Roundtable.Client.Relay do
  @moduledoc """
  Forwards room activity from the service node to a remote subscriber.

  `Phoenix.PubSub.subscribe/2` registers the calling process, and an `:erpc`
  call runs in a short-lived worker on the service node, so a remote client
  cannot subscribe directly. This process subscribes on the service node's
  behalf and relays each notification to the client's pid, which the BEAM
  delivers across the node connection like any other message.

  The relay monitors its subscriber and exits with it, so a client that
  disappears leaves nothing behind.
  """
  alias Roundtable.Chat

  @doc "Starts a relay on the current node for `subscriber`. Returns its pid."
  def start(subscriber, room_id) when is_pid(subscriber) do
    pid =
      spawn(fn ->
        Process.monitor(subscriber)
        Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")
        if room_id, do: Chat.subscribe(room_id)
        send(subscriber, :watch_ready)
        loop(subscriber, room_id)
      end)

    {:ok, pid}
  end

  defp loop(subscriber, room_id) do
    receive do
      {:watch, ^room_id} ->
        loop(subscriber, room_id)

      {:watch, next} ->
        if room_id, do: Phoenix.PubSub.unsubscribe(Roundtable.PubSub, "room:#{room_id}")
        if next, do: Chat.subscribe(next)
        loop(subscriber, next)

      {:DOWN, _, :process, ^subscriber, _} ->
        :ok

      message when message in [:room_updated, :rooms_updated] ->
        send(subscriber, message)
        loop(subscriber, room_id)

      _other ->
        loop(subscriber, room_id)
    end
  end
end
