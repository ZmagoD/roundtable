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

  test "decodes every bound control key" do
    bindings = [
      {1, :home},
      {3, :ctrl_c},
      {4, :ctrl_d},
      {5, :end_key},
      {7, :ctrl_g},
      {8, :backspace},
      {9, :tab},
      {12, :ctrl_l},
      {16, :ctrl_p},
      {20, :ctrl_t},
      {21, :ctrl_u},
      {23, :ctrl_w},
      {127, :backspace}
    ]

    for {byte, key} <- bindings do
      assert {[^key], ""} = Keys.decode(<<byte>>), "byte #{byte} should decode to #{key}"
    end
  end

  test "decodes the application-cursor form of home and end" do
    assert {[:home, :end_key], ""} = Keys.decode("\eOH\eOF")
  end

  test "an unbound SS3 sequence is consumed, not typed" do
    assert {[{:char, "x"}], ""} = Keys.decode("\eOP" <> "x")
    assert {[], "\eO"} = Keys.decode("\eO")
  end

  test "decodes modified and numbered sequences by their final byte" do
    # Terminals prefix parameters: shift-up is "\e[1;2A".
    assert {[:up], ""} = Keys.decode("\e[1;2A")
    assert {[:home, :end_key], ""} = Keys.decode("\e[1~\e[4~")
    assert {[:back_tab], ""} = Keys.decode("\e[Z")
    assert {[], "\e[1;2"} = Keys.decode("\e[1;2")
  end

  test "control bytes with no binding are dropped rather than typed" do
    assert {[{:char, "a"}], ""} = Keys.decode(<<0>> <> "a" <> <<2>>)
  end

  test "carriage return and newline are the same key" do
    assert {[:enter, :enter], ""} = Keys.decode("\r\n")
  end

  test "a three-byte character needs all three bytes" do
    <<a, b, c>> = "€"
    assert {[], <<a, b>>} = Keys.decode(<<a, b>>)
    assert {[{:char, "€"}], ""} = Keys.decode(<<a, b, c>>)
  end

  test "a stream is decoded the same whether it arrives whole or in pieces" do
    stream = "hi\e[Athere\e[5~\r🙂"
    {whole, ""} = Keys.decode(stream)

    {piecemeal, rest} =
      stream
      |> :binary.bin_to_list()
      |> Enum.reduce({[], ""}, fn byte, {keys, buffer} ->
        {new_keys, rest} = Keys.decode(buffer <> <<byte>>)
        {keys ++ new_keys, rest}
      end)

    assert rest == ""
    assert piecemeal == whole
  end
end
