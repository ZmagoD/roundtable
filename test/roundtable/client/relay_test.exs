defmodule Roundtable.Client.RelayTest do
  @moduledoc """
  The relay is what lets a terminal on the other end of a node connection see
  room activity at all. It is small, and every part of it is a way to leak a
  process or lose an update.
  """
  use Roundtable.DataCase, async: false

  alias Roundtable.Chat
  alias Roundtable.Client.Relay

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Relayed", "directory" => File.cwd!()})
    {:ok, other} = Chat.create_room(%{"name" => "Elsewhere", "directory" => File.cwd!()})
    %{room: room, other: other}
  end

  test "forwards the room it was started for", %{room: room} do
    {:ok, _relay} = Relay.start(self(), room.id)
    assert_receive :watch_ready

    Chat.broadcast(room.id)
    assert_receive :room_updated
  end

  test "forwards room-list changes regardless of which room is watched", %{room: room} do
    {:ok, _relay} = Relay.start(self(), room.id)
    assert_receive :watch_ready

    Phoenix.PubSub.broadcast(Roundtable.PubSub, "rooms", :rooms_updated)
    assert_receive :rooms_updated
  end

  test "a room it is not watching does not reach the subscriber", %{room: room, other: other} do
    {:ok, _relay} = Relay.start(self(), room.id)
    assert_receive :watch_ready

    Chat.broadcast(other.id)
    refute_receive :room_updated, 200
  end

  test "following a different room stops the old one", %{room: room, other: other} do
    {:ok, relay} = Relay.start(self(), room.id)
    assert_receive :watch_ready

    send(relay, {:watch, other.id})
    # Let the relay resubscribe before asserting on either room.
    Process.sleep(50)

    Chat.broadcast(other.id)
    assert_receive :room_updated

    Chat.broadcast(room.id)
    refute_receive :room_updated, 200
  end

  test "asking for the room it already watches changes nothing", %{room: room} do
    {:ok, relay} = Relay.start(self(), room.id)
    assert_receive :watch_ready

    send(relay, {:watch, room.id})
    Process.sleep(50)

    Chat.broadcast(room.id)
    assert_receive :room_updated
  end

  test "starts without a room and can be pointed at one later", %{room: room} do
    {:ok, relay} = Relay.start(self(), nil)
    assert_receive :watch_ready

    Chat.broadcast(room.id)
    refute_receive :room_updated, 200

    send(relay, {:watch, room.id})
    Process.sleep(50)

    Chat.broadcast(room.id)
    assert_receive :room_updated
  end

  test "dies with its subscriber, leaving nothing behind", %{room: room} do
    test = self()

    subscriber =
      spawn(fn ->
        {:ok, relay} = Relay.start(self(), room.id)
        send(test, {:relay, relay})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:relay, relay}
    assert Process.alive?(relay)

    ref = Process.monitor(relay)
    send(subscriber, :stop)

    assert_receive {:DOWN, ^ref, :process, ^relay, _}
  end

  test "ignores messages it does not understand", %{room: room} do
    {:ok, relay} = Relay.start(self(), room.id)
    assert_receive :watch_ready

    send(relay, :nonsense)
    Chat.broadcast(room.id)

    assert_receive :room_updated
    assert Process.alive?(relay)
  end
end
