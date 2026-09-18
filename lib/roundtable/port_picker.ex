defmodule Roundtable.PortPicker do
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
    Enum.find(start..min(start + 99, 65535), fn port ->
      if port in [3000, 4000] do
        false
      else
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
    end) || raise "No free port found near #{start}"
  end
end
