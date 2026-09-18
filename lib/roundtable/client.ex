defmodule Roundtable.Client do
  @moduledoc """
  Coordination API for clients that are not the web UI.

  A client either runs inside the service node (`local/0`) or attaches to a
  running service over distributed Erlang (`connect/2`). Every call goes to the
  node that owns the database, so a terminal session never starts a second
  coordinator against the same SQLite file.

  Read calls fail fast; calls that schedule work wait longer, because the
  coordinator serializes queue transitions.
  """
  alias Roundtable.{Chat, Coordinator}

  defstruct [:node]

  @type t :: %__MODULE__{node: node() | nil}

  @read_timeout 5_000
  @write_timeout 15_000

  @doc "A client that calls the service running in this same node."
  def local, do: %__MODULE__{}

  @doc """
  Attaches to a running service node, setting the shared cookie first.

  Returns `{:error, :not_running}` when the node is up but unreachable, which
  is almost always "the service was never started".
  """
  def connect(node, cookie \\ nil) when is_atom(node) do
    if Node.alive?() do
      if cookie, do: Node.set_cookie(node, cookie)

      if Node.connect(node) == true,
        do: {:ok, %__MODULE__{node: node}},
        else: {:error, :not_running}
    else
      {:error, :no_distribution}
    end
  end

  @doc "Human-readable description of where this client is talking to."
  def describe(%__MODULE__{node: nil}), do: "in-process"
  def describe(%__MODULE__{node: node}), do: to_string(node)

  def rooms(c), do: call(c, Chat, :rooms, [])
  def agents(c, room_id), do: call(c, Chat, :agents, [room_id])
  def messages(c, room_id), do: call(c, Chat, :messages, [room_id])
  def runs(c, room_id), do: call(c, Chat, :runs, [room_id])
  def model_presets(c), do: call(c, Chat, :model_presets, [])

  def approvals(c, room_id) do
    case call(c, Coordinator, :approvals, []) do
      {:error, _} = error -> error
      map -> map |> Map.values() |> Enum.filter(&(&1.room_id == room_id))
    end
  end

  def create_room(c, attrs), do: call(c, Chat, :create_room, [attrs], @write_timeout)

  def create_agent(c, room_id, attrs),
    do: call(c, Chat, :create_agent, [room_id, attrs], @write_timeout)

  def cross_room_request(c, kind, room_id, target, body),
    do: call(c, Chat, :request_from_room, [kind, room_id, target, body], @write_timeout)

  def remove_agent(c, agent_id),
    do: call(c, Coordinator, :remove_agent, [agent_id], @write_timeout)

  def remove_room(c, room_id), do: call(c, Coordinator, :remove_room, [room_id], @write_timeout)

  def update_agent(c, agent_id, attrs),
    do: call(c, Chat, :update_agent, [agent_id, attrs], @write_timeout)

  def update_room(c, room_id, attrs),
    do: call(c, Chat, :update_room, [room_id, attrs], @write_timeout)

  def post(c, room_id, body, opts \\ []),
    do: call(c, Coordinator, :post, [room_id, body, opts], @write_timeout)

  def stop(c, agent_id), do: call(c, Coordinator, :stop, [agent_id], @write_timeout)
  def reset(c, agent_id), do: call(c, Coordinator, :reset, [agent_id], @write_timeout)
  def retry(c, run_id), do: call(c, Coordinator, :retry, [run_id], @write_timeout)

  def approve(c, run_id, request_id, decision),
    do: call(c, Coordinator, :approve, [run_id, request_id, decision], @write_timeout)

  def assignment(c, agent, preset_id, purpose),
    do: call(c, Chat, :assignment, [agent, preset_id, purpose])

  @doc """
  Streams room activity to `subscriber` until it dies.

  Locally this is a plain PubSub subscription. Against a remote service a relay
  process is started *on that node*, because a subscription registers the
  calling process and `:erpc` would register its own short-lived worker.
  """
  def watch(%__MODULE__{node: nil}, subscriber, room_id) do
    send(subscriber, :watch_ready)
    Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")
    if room_id, do: Chat.subscribe(room_id)
    {:ok, :local}
  end

  def watch(%__MODULE__{} = c, subscriber, room_id) do
    call(c, Roundtable.Client.Relay, :start, [subscriber, room_id])
  end

  @doc "Points an existing relay at a different room."
  def rewatch(%__MODULE__{node: nil}, _relay, previous, room_id) do
    if previous, do: Phoenix.PubSub.unsubscribe(Roundtable.PubSub, "room:#{previous}")
    if room_id, do: Chat.subscribe(room_id)
    :ok
  end

  def rewatch(%__MODULE__{}, relay, _previous, room_id) when is_pid(relay) do
    send(relay, {:watch, room_id})
    :ok
  end

  def rewatch(_, _, _, _), do: :ok

  defp call(client, module, fun, args, timeout \\ @read_timeout)

  defp call(%__MODULE__{node: nil}, module, fun, args, _timeout),
    do: apply(module, fun, args)

  defp call(%__MODULE__{node: node}, module, fun, args, timeout) do
    :erpc.call(node, module, fun, args, timeout)
  catch
    :error, {:erpc, :noconnection} -> {:error, :disconnected}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    :error, {:exception, exception, _} -> {:error, Exception.message(exception)}
    kind, reason -> {:error, Exception.format(kind, reason)}
  end
end
