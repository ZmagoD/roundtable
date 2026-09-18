defmodule Roundtable.TUI.Keys do
  @moduledoc """
  Decodes a raw terminal byte stream into key events.

  Pure and incremental: `decode/1` returns the keys it could complete plus the
  bytes it could not, which the caller feeds back in with the next read. A lone
  escape only becomes `:escape` once a following byte proves it was not the
  start of a sequence, so partial reads never produce a phantom keypress.
  """

  @doc "Returns `{keys, leftover_bytes}`."
  def decode(buffer) when is_binary(buffer), do: decode(buffer, [])

  defp decode(<<>>, keys), do: {Enum.reverse(keys), <<>>}

  # Escape sequences. An incomplete one stays in the buffer.
  defp decode(<<"\e[", rest::binary>> = buffer, keys) do
    case csi(rest) do
      {:ok, key, tail} -> decode(tail, [key | keys])
      :incomplete -> {Enum.reverse(keys), buffer}
    end
  end

  defp decode(<<"\eO", rest::binary>> = buffer, keys) do
    case rest do
      <<"H", tail::binary>> -> decode(tail, [:home | keys])
      <<"F", tail::binary>> -> decode(tail, [:end_key | keys])
      <<_, tail::binary>> -> decode(tail, keys)
      <<>> -> {Enum.reverse(keys), buffer}
    end
  end

  defp decode(<<"\e">> = buffer, keys), do: {Enum.reverse(keys), buffer}
  defp decode(<<"\e", rest::binary>>, keys), do: decode(rest, [:escape | keys])

  defp decode(<<"\r", rest::binary>>, keys), do: decode(rest, [:enter | keys])
  defp decode(<<"\n", rest::binary>>, keys), do: decode(rest, [:enter | keys])
  defp decode(<<"\t", rest::binary>>, keys), do: decode(rest, [:tab | keys])
  defp decode(<<127, rest::binary>>, keys), do: decode(rest, [:backspace | keys])
  defp decode(<<8, rest::binary>>, keys), do: decode(rest, [:backspace | keys])
  defp decode(<<1, rest::binary>>, keys), do: decode(rest, [:home | keys])
  defp decode(<<3, rest::binary>>, keys), do: decode(rest, [:ctrl_c | keys])
  defp decode(<<4, rest::binary>>, keys), do: decode(rest, [:ctrl_d | keys])
  defp decode(<<5, rest::binary>>, keys), do: decode(rest, [:end_key | keys])
  defp decode(<<7, rest::binary>>, keys), do: decode(rest, [:ctrl_g | keys])
  defp decode(<<12, rest::binary>>, keys), do: decode(rest, [:ctrl_l | keys])
  defp decode(<<20, rest::binary>>, keys), do: decode(rest, [:ctrl_t | keys])
  defp decode(<<21, rest::binary>>, keys), do: decode(rest, [:ctrl_u | keys])
  defp decode(<<23, rest::binary>>, keys), do: decode(rest, [:ctrl_w | keys])

  # Multi-byte UTF-8 needs every continuation byte before it is a character.
  defp decode(<<byte, _::binary>> = buffer, keys) when byte >= 0xC2 do
    expected = utf8_length(byte)

    case buffer do
      <<char::binary-size(^expected), tail::binary>> ->
        decode(tail, [{:char, char} | keys])

      _ ->
        {Enum.reverse(keys), buffer}
    end
  end

  defp decode(<<byte, rest::binary>>, keys) when byte >= 32,
    do: decode(rest, [{:char, <<byte>>} | keys])

  # Any other control byte is not bound to anything.
  defp decode(<<_, rest::binary>>, keys), do: decode(rest, keys)

  defp csi(<<"A", rest::binary>>), do: {:ok, :up, rest}
  defp csi(<<"B", rest::binary>>), do: {:ok, :down, rest}
  defp csi(<<"C", rest::binary>>), do: {:ok, :right, rest}
  defp csi(<<"D", rest::binary>>), do: {:ok, :left, rest}
  defp csi(<<"H", rest::binary>>), do: {:ok, :home, rest}
  defp csi(<<"F", rest::binary>>), do: {:ok, :end_key, rest}
  defp csi(<<"Z", rest::binary>>), do: {:ok, :back_tab, rest}
  defp csi(<<"1~", rest::binary>>), do: {:ok, :home, rest}
  defp csi(<<"3~", rest::binary>>), do: {:ok, :delete, rest}
  defp csi(<<"4~", rest::binary>>), do: {:ok, :end_key, rest}
  defp csi(<<"5~", rest::binary>>), do: {:ok, :page_up, rest}
  defp csi(<<"6~", rest::binary>>), do: {:ok, :page_down, rest}
  defp csi(<<>>), do: :incomplete

  defp csi(<<byte, rest::binary>>) when byte in ?0..?9 or byte == ?; do
    case csi(rest) do
      {:ok, key, tail} -> {:ok, key, tail}
      :incomplete -> :incomplete
    end
  end

  # A sequence this client does not bind: consume it so it cannot be typed.
  defp csi(<<_, rest::binary>>), do: {:ok, :unknown, rest}

  defp utf8_length(byte) when byte >= 0xF0, do: 4
  defp utf8_length(byte) when byte >= 0xE0, do: 3
  defp utf8_length(_), do: 2
end
