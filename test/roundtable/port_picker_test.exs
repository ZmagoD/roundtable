defmodule Roundtable.PortPickerTest do
  use ExUnit.Case, async: true

  test "skips an occupied port and reserves development ports" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    selected = Roundtable.PortPicker.pick(port)
    assert selected > port
    refute selected in [3000, 4000]
    assert Roundtable.PortPicker.pick(4000) > 4000
  end
end
