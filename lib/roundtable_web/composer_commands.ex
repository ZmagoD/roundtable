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
    {"help", "", "Show the browser chat commands", []}
  ]

  def suggestions(agents) do
    names = Enum.map(agents, & &1.name)

    Enum.map(@commands, fn {name, usage, description, choices} ->
      %{
        name: name,
        usage: usage,
        description: description,
        choices:
          Enum.map(choices, fn
            :agents -> names
            :heads -> names ++ ["off"]
            values -> values
          end)
      }
    end)
  end

  def parse(body, agents), do: dispatch(String.split(body), agents)

  defp dispatch(["/clear-history"], _agents), do: {:panel, "clear-history"}
  defp dispatch(["/work"], _agents), do: {:event, "open-work", %{}}
  defp dispatch(["/context"], _agents), do: {:event, "edit-room", %{}}
  defp dispatch(["/schedules"], _agents), do: {:event, "panel", %{"name" => "schedules"}}
  defp dispatch(["/help"], _agents), do: {:panel, "commands"}
  defp dispatch(["/head", "off"], _agents), do: {:event, "clear-team-head", %{}}
  defp dispatch(["/head", name], agents), do: agent_event(agents, name, "make-team-head")
  defp dispatch(["/stop", name], agents), do: agent_event(agents, name, "stop")

  defp dispatch(["/quota-retry", name, value], agents) when value in ~w(on off) do
    case find_agent(agents, name) do
      nil -> {:error, "No participant named #{name} in this room."}
      agent -> {:quota_retry, agent.id, value == "on"}
    end
  end

  defp dispatch(_, _agents),
    do: {:error, "Unknown or incomplete command. Type / for suggestions or /help for commands."}

  defp agent_event(agents, name, event) do
    case find_agent(agents, name) do
      nil -> {:error, "No participant named #{name} in this room."}
      agent -> {:event, event, %{"id" => to_string(agent.id)}}
    end
  end

  defp find_agent(agents, name), do: Enum.find(agents, &(&1.name == String.downcase(name)))
end
