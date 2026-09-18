defmodule Mix.Tasks.Tui do
  @shortdoc "Opens the Roundtable terminal client"

  @moduledoc """
  Attaches a terminal client to a running Roundtable service.

      mix tui                          # attach to roundtable@<hostname>
      mix tui --node roundtable@box    # attach to a named node
      mix tui --local                  # run the service in this process instead

  The service owns the database, so `--local` is only for a machine where the
  background service is *not* running. Starting a second service against the
  same database gives you two coordinators fighting over one delivery queue.

  The cookie is read from `ROUNDTABLE_COOKIE`, then from the release's
  `releases/COOKIE`, which `bin/roundtable setup` generates.

  `bin/roundtable tui` is the supported entry point; it passes `+Bc` so that
  Ctrl-C reaches the client instead of opening the emulator's break menu. When
  running this task directly, either start it the same way:

      elixir --erl "+Bc" -S mix tui

  or leave the room with `/quit` or Ctrl-D, which need no flag.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [node: :string, cookie: :string, local: :boolean])

    case client(opts) do
      {:ok, client} ->
        case Roundtable.TUI.run(client) do
          {:error, :no_terminal} -> abort("mix tui needs a terminal; it cannot be piped.")
          _ -> :ok
        end

      {:error, message} ->
        abort(message)
    end
  end

  defp client(opts) do
    if opts[:local] do
      Mix.Task.run("app.start")
      {:ok, Roundtable.Client.local()}
    else
      remote(opts)
    end
  end

  defp remote(opts) do
    node = String.to_atom(opts[:node] || System.get_env("ROUNDTABLE_NODE") || default_node())

    with {:ok, distribution} <- distribute(),
         {:ok, cookie} <- cookie(opts, distribution) do
      case Roundtable.Client.connect(node, cookie) do
        {:ok, client} ->
          {:ok, client}

        {:error, :not_running} ->
          {:error,
           "No Roundtable service at #{node}.\nStart it with bin/roundtable start, " <>
             "or run a standalone client with mix tui --local."}

        {:error, reason} ->
          {:error, "Could not reach #{node}: #{inspect(reason)}"}
      end
    end
  end

  # Reports whether this task started distribution or inherited it, because
  # that decides whether the VM's own cookie or the release file wins below.
  defp distribute do
    if Node.alive?() do
      {:ok, :inherited}
    else
      name = :"roundtable_tui_#{System.unique_integer([:positive])}"

      case Node.start(name, :shortnames) do
        {:ok, _} -> {:ok, :started}
        {:error, reason} -> {:error, "Could not start distribution: #{inspect(reason)}"}
      end
    end
  end

  # A cookie the caller gave us always wins. A VM started with `--cookie`
  # already carries the operator's choice, so respect it before falling back to
  # the release file; only a node we started ourselves defaults to that file.
  defp cookie(opts, distribution) do
    inherited = Node.get_cookie()

    cond do
      opts[:cookie] ->
        {:ok, String.to_atom(opts[:cookie])}

      cookie = System.get_env("ROUNDTABLE_COOKIE") ->
        {:ok, String.to_atom(cookie)}

      distribution == :inherited and inherited != :nocookie ->
        {:ok, inherited}

      File.exists?(release_cookie()) ->
        {:ok, release_cookie() |> File.read!() |> String.trim() |> String.to_atom()}

      inherited != :nocookie ->
        {:ok, inherited}

      true ->
        {:error, "No cookie found. Run bin/roundtable setup, or pass --cookie."}
    end
  end

  defp release_cookie,
    do: Path.join([File.cwd!(), "_build", "prod", "rel", "roundtable", "releases", "COOKIE"])

  defp default_node do
    {hostname, 0} = System.cmd("hostname", ["-s"])
    "roundtable@#{String.trim(hostname)}"
  rescue
    _ -> "roundtable@localhost"
  end

  defp abort(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
