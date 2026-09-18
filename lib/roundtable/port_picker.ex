defmodule Roundtable.PortPicker do
  @moduledoc """
  Chooses a free loopback port at boot.

  A local tool should not fail to start because something else took its port,
  so it scans forward from the preferred one. The probe is best effort: another
  process can claim a port between the check and the web server binding it.
  """
  require Logger

  def configure do
    config = Application.fetch_env!(:roundtable, RoundtableWeb.Endpoint)

    if config[:server] || Application.get_env(:phoenix, :serve_endpoints, false) do
      preferred = Application.get_env(:roundtable, :preferred_port, 4317)
      port = pick(preferred)

      config =
        config
        |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: port)
        |> Keyword.put(:url, host: "localhost", port: port)

      Application.put_env(:roundtable, RoundtableWeb.Endpoint, config)
      Logger.info("Roundtable: http://127.0.0.1:#{port}")
    end
  end

  def pick(start) do
    Enum.find(start..min(start + 99, 65_535), &available?/1) ||
      raise "No free port found near #{start}"
  end

  # Ports other local tools expect to own.
  defp available?(port) when port in [3000, 4000], do: false

  defp available?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, reason} ->
        raise "Cannot bind local port: #{inspect(reason)}"
    end
  end
end
