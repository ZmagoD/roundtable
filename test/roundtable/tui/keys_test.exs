defmodule Roundtable.TUI.KeysTest do
  use ExUnit.Case, async: true
  alias Roundtable.TUI.Keys

  test "decodes printable characters" do
    assert {[{:char, "h"}, {:char, "i"}], ""} = Keys.decode("hi")
  end

  test "decodes arrow keys and page movement" do
    assert {[:up, :down, :right, :left], ""} = Keys.decode("\e[A\e[B\e[C\e[D")
    assert {[:page_up, :page_down], ""} = Keys.decode("\e[5~\e[6~")
    assert {[:home, :end_key, :delete], ""} = Keys.decode("\e[H\e[F\e[3~")
  end

  test "decodes control keys" do
    assert {[:enter, :backspace, :tab, :ctrl_c, :ctrl_l], ""} =
             Keys.decode("\r" <> <<127>> <> "\t" <> <<3, 12>>)
  end

  test "holds an incomplete escape sequence until the rest arrives" do
    assert {[], "\e["} = Keys.decode("\e[")
    assert {[:up], ""} = Keys.decode("\e[" <> "A")
  end

  test "a lone escape is only a keypress once another byte proves it" do
    assert {[], "\e"} = Keys.decode("\e")
    assert {[:escape, {:char, "a"}], ""} = Keys.decode("\ea")
  end

  test "waits for every byte of a multi-byte character" do
    <<first, rest::binary>> = "é"
    assert {[], <<first>>} = Keys.decode(<<first>>)
    assert {[{:char, "é"}], ""} = Keys.decode(<<first>> <> rest)
    assert {[{:char, "🙂"}], ""} = Keys.decode("🙂")
  end

  test "consumes unbound escape sequences instead of typing them" do
    assert {[:unknown, {:char, "x"}], ""} = Keys.decode("\e[200~x")
  end
end
