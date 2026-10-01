defmodule RoundtableWeb.ComposerCommands do
  @moduledoc "Browser composer commands and the choices offered as they are typed."

  @commands [
    {"clear-history", "", "Clear this room's chat after confirmation", []},
    {"quota-retry", "<agent> on|off", "Resume an agent after quota limits reset",
     [:agents, ~w(on off)]},
    {"head", "<agent|off>", "Choose the primary contact", [:heads]},
    {"work", "", "Open the shared work document", []},
    {"context", "", "Edit the room brief", []},
    {"schedules", "", "Manage scheduled instructions", []},
    {"stop", "<agent>", "Stop an agent and clear its queue", [:agents]},
    {"auto", "<agent> on|off", "Choose whether an agent approves its own tools",
     [:agents, ~w(on off)]},
    {"model", "<agent> <id|default>", "Set a model or use the provider default",
     [:agents, ~w(default)]},
    {"role", "<agent> <text>", "Change a participant's role", [:agents]},
    {"reset", "<agent>", "Start a fresh session; history stays", [:agents]},
    {"retry", "[run]", "Retry a run, or the newest run needing attention", [:runs]},
    {"approve", "accept|decline [n]", "Answer a numbered pending approval",
     [~w(accept decline), :approvals]},
    {"rename", "<agent> <new>", "Rename a participant before its first turn", [:agents]},
    {"remove", "<agent>", "Remove a participant after confirmation", [:agents]},
    {"who", "", "Show the room's participants and their status", []},
    {"help", "", "Show the browser chat commands", []}
  ]

  def suggestions(agents, runs \\ [], approvals \\ []) do
    names = Enum.map(agents, & &1.name)

    Enum.map(@commands, fn {name, usage, description, choices} ->
      %{
        name: name,
        usage: usage,
        description: description,
        choices:
          Enum.map(choices, fn
            :agents ->
              names

            :heads ->
              names ++ ["off"]

            :runs ->
              Enum.map(retryable(runs), &to_string(&1.id))

            :approvals ->
              approvals |> Enum.with_index(1) |> Enum.map(fn {_, n} -> to_string(n) end)

            values ->
              values
          end)
      }
    end)
  end

  def parse(body, agents, context \\ []) do
    case String.split(body, ~r/\s+/, parts: 3, trim: true) do
      ["/role", name, text] -> update_agent(agents, name, %{"role" => text})
      _ -> parse_tokens(String.split(body), agents, context)
    end
  end

  defp parse_tokens(["/retry" | args], _agents, context) do
    runs = retryable(Keyword.get(context, :runs, []))

    run =
      case args do
        [] -> List.first(runs)
        [id] -> Enum.find(runs, &(to_string(&1.id) == id))
        _ -> nil
      end

    if run,
      do: {:event, "retry", %{"id" => to_string(run.id)}},
      else: {:error, "No matching run to retry. Type /retry for available run numbers."}
  end

  defp parse_tokens(["/approve", decision | args], _agents, context)
       when decision in ~w(accept decline) do
    approvals = Keyword.get(context, :approvals, [])

    number =
      case args do
        [] -> "1"
        [number] -> number
        _ -> ""
      end

    approval =
      approvals
      |> Enum.with_index(1)
      |> Enum.find_value(fn {approval, index} -> if to_string(index) == number, do: approval end)

    if approval do
      {:event, "approval",
       %{
         "run" => to_string(approval.run_id),
         "request" => Jason.encode!(approval.request_id),
         "decision" => decision
       }}
    else
      {:error, "No matching approval is pending. Type /approve accept for available numbers."}
    end
  end

  defp parse_tokens(tokens, agents, _context), do: dispatch(tokens, agents)

  defp retryable(runs) do
    runs
    |> Enum.filter(&(&1.status in ~w(failed interrupted stopped waiting_quota)))
    |> Enum.sort_by(& &1.id, :desc)
  end

  defp dispatch(["/clear-history"], _agents), do: {:panel, "clear-history"}
  defp dispatch(["/work"], _agents), do: {:event, "open-work", %{}}
  defp dispatch(["/context"], _agents), do: {:event, "edit-room", %{}}
  defp dispatch(["/schedules"], _agents), do: {:event, "panel", %{"name" => "schedules"}}
  defp dispatch(["/help"], _agents), do: {:panel, "commands"}
  defp dispatch(["/head", "off"], _agents), do: {:event, "clear-team-head", %{}}
  defp dispatch(["/head", name], agents), do: agent_event(agents, name, "make-team-head")
  defp dispatch(["/who"], _agents), do: {:panel, "roster"}
  defp dispatch(["/reset", name], agents), do: agent_event(agents, name, "reset")
  defp dispatch(["/remove", name], agents), do: agent_event(agents, name, "confirm-remove-agent")
  defp dispatch(["/rename", name, new], agents), do: update_agent(agents, name, %{"name" => new})

  defp dispatch(["/auto", name, value], agents) when value in ~w(on off),
    do: update_agent(agents, name, %{"auto_approve" => value == "on"})

  defp dispatch(["/model", name, model], agents),
    do: update_agent(agents, name, %{"model" => if(model == "default", do: nil, else: model)})

  defp dispatch(["/stop", name], agents), do: agent_event(agents, name, "stop")

  defp dispatch(["/quota-retry", name, value], agents) when value in ~w(on off) do
    case find_agent(agents, name) do
      nil -> {:error, "No participant named #{name} in this room."}
      agent -> {:quota_retry, agent.id, value == "on"}
    end
  end

  defp dispatch(_, _agents),
    do: {:error, "Unknown or incomplete command. Type / for suggestions or /help for commands."}

  defp update_agent(agents, name, attrs) do
    case find_agent(agents, name) do
      nil ->
        {:error, "No participant named #{name} in this room. Type / for participant choices."}

      agent ->
        {:update_agent, agent.id, attrs}
    end
  end

  defp agent_event(agents, name, event) do
    case find_agent(agents, name) do
      nil -> {:error, "No participant named #{name} in this room."}
      agent -> {:event, event, %{"id" => to_string(agent.id)}}
    end
  end

  defp find_agent(agents, name), do: Enum.find(agents, &(&1.name == String.downcase(name)))
end
