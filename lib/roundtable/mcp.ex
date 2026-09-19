defmodule Roundtable.MCP do
  @moduledoc """
  The rooms themselves, offered to a participant as tools.

  Setting a team up is form-filling: a room, a directory, a brief, four
  participants. The person doing it is usually already here, talking to an
  agent, so these tools let them ask for it instead — the agent calls back into
  the service over MCP and the room appears.

  Everything goes through `Roundtable.Chat`, so a participant building a room is
  held to exactly the rules the browser form is held to. Nothing here removes
  anything: a room that should not have been made is one the human deletes,
  rather than history an agent can lose on a misreading.

  Who is calling is a signed token, minted for a participant when its turn
  starts and handed to that CLI for that turn alone. It is what makes "this
  room" mean something, and its short life is what stops a token left behind in
  a log from being a standing key to the service.
  """
  alias Roundtable.{Agents, Chat, Coordinator}
  alias Roundtable.Chat.Schedule

  @salt "roundtable mcp participant"

  # A turn is capped at thirty minutes (`Agents.Worker`), so a signature older
  # than that belongs to no turn at all. This is the outer bound; what actually
  # ends a token's life is its own run finishing — see `participant/1`.
  @max_age 30 * 60

  # Providers whose CLI takes an MCP server on the command line *and* has an
  # approval channel back to the room. Without the second, a participant could
  # rearrange the rooms with nowhere for the human to say no.
  @providers ["claude", "codex"]

  @doc """
  Where the tool server answers, or `nil` when there is nothing to reach.

  Only the node serving HTTP can answer, so a client started with `--local`
  offers no tools rather than handing agents an address that answers nothing.
  Set `config :roundtable, :mcp_url, false` to turn the tools off entirely.
  """
  def url do
    case Application.get_env(:roundtable, :mcp_url, :endpoint) do
      :endpoint -> if serving?(), do: RoundtableWeb.Endpoint.url() <> "/mcp"
      url when is_binary(url) -> url
      _ -> nil
    end
  end

  @doc "Whether this participant's CLI is one the tools can be wired into."
  def offered?(%{provider: provider} = agent),
    do: provider in @providers and is_integer(Map.get(agent, :id)) and url() != nil

  def offered?(_agent), do: false

  @doc """
  A bearer token that says which participant is calling, and for which turn.

  Minted when a turn launches, by which point its run is already `running`, so
  the run is what the token is anchored to. A token minted outside a turn names
  no run and is refused on use rather than being quietly useful.
  """
  def token(%{id: id}) do
    run_id = with run when not is_nil(run) <- Chat.active_run(id), do: run.id
    Phoenix.Token.sign(RoundtableWeb.Endpoint, @salt, {id, run_id})
  end

  @doc """
  The participant a bearer token names, while its turn is still running.

  The signature alone is not enough. A CLI outlives the turn that started it,
  the token is in that process's environment and in the environment of every
  command it runs, and a copy taken from there would otherwise keep working
  long after the human stopped watching. So the run is checked, every call: when
  the turn is over the token is over, whatever its signature still says.
  """
  def participant(token) when is_binary(token) do
    with {:ok, {id, run_id}} <-
           Phoenix.Token.verify(RoundtableWeb.Endpoint, @salt, token, max_age: @max_age),
         # Whether it is still in a room is the more useful thing to say, so it
         # is asked first: a participant that has gone hears that, not that its
         # turn ended.
         agent = Chat.agent!(id),
         :ok <- turn_in_progress(id, run_id) do
      {:ok, agent}
    else
      # A signature from before tokens named their run verifies but says nothing
      # about which turn it belongs to, so it is no longer a token.
      {:ok, _unnamed_run} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :gone}
  end

  def participant(_token), do: {:error, :invalid}

  # `:expired` is what the plug tells the caller, and it is now true for the
  # reason it always claimed: the turn this token belongs to has ended.
  defp turn_in_progress(_id, nil), do: {:error, :expired}

  defp turn_in_progress(id, run_id) do
    case Chat.active_run(id) do
      %{id: ^run_id} -> :ok
      _other -> {:error, :expired}
    end
  end

  @doc "Every tool, in the shape an MCP client expects to read it."
  def tools do
    [
      %{
        name: "list_rooms",
        description:
          "Every room here: its name, working directory, shared brief, and who is in it.",
        inputSchema: object(%{})
      },
      %{
        name: "list_participants",
        description: "The participants in one room, with what each is for and what it runs on.",
        inputSchema: object(%{"room" => room_property()})
      },
      %{
        name: "list_profiles",
        description:
          "The saved participant profiles. A profile is a template — adding one to a room " <>
            "creates a participant there with its own session.",
        inputSchema: object(%{})
      },
      %{
        name: "list_providers",
        description:
          "The agent CLIs this machine can run, whether each is installed, and model names " <>
            "worth offering for it.",
        inputSchema: object(%{})
      },
      %{
        name: "create_room",
        description:
          "Makes a room: a working tree, a brief, and the participants you then add to it. " <>
            "The room starts empty; add_participant fills it.",
        inputSchema:
          object(
            %{
              "name" => string("What the room is called, as a person would say it."),
              "directory" =>
                string(
                  "Absolute path to the working tree this room is about. Defaults to the " <>
                    "directory of the room you are in."
                ),
              "brief" => brief_property()
            },
            ["name"]
          )
      },
      %{
        name: "update_room",
        description: "Changes a room's name or its shared brief. Its directory cannot move.",
        inputSchema:
          object(%{
            "room" => room_property(),
            "name" => string("A new name for the room."),
            "brief" => brief_property()
          })
      },
      %{
        name: "add_participant",
        description:
          "Adds a participant to a room, from a saved profile or from scratch. It works in " <>
            "the room's directory and gets its own session.",
        inputSchema:
          object(%{
            "room" => room_property(),
            "profile" =>
              string("A saved profile to add, by name or id. list_profiles shows the library."),
            "name" =>
              string(
                "What to call it in the room: lowercase letters, digits, - and _. With a " <>
                  "profile this overrides the profile's own name, which is how the same " <>
                  "profile can be in a room twice."
              ),
            "provider" => string("Which CLI runs it: #{Enum.join(Agents.ids(), ", ")}."),
            "model" => string("Model id for that provider. Leave it out for the CLI's default."),
            "role" => role_property(),
            "cost_tier" => cost_tier_property()
          })
      },
      %{
        name: "update_participant",
        description:
          "Changes what a participant is for and what it runs on. Its provider and directory " <>
            "stay fixed, and it can only be renamed before its first turn.",
        inputSchema:
          object(
            %{
              "participant" => string("Who to change, by name or id."),
              "room" => room_property(),
              "name" => string("A new name, while it has not taken a turn yet."),
              "model" => string("Model id for its provider."),
              "role" => role_property(),
              "cost_tier" => cost_tier_property()
            },
            ["participant"]
          )
      },
      %{
        name: "create_profile",
        description:
          "Saves a participant worth having again: provider, model, cost tier, role, " <>
            "approvals. A template, not a participant — it joins no room by itself.",
        inputSchema:
          object(
            %{
              "name" => string("Profile name, and the default name it takes in a room."),
              "provider" => string("Which CLI runs it: #{Enum.join(Agents.ids(), ", ")}."),
              "model" => string("Model id for that provider."),
              "role" => role_property(),
              "cost_tier" => cost_tier_property()
            },
            ["name", "provider"]
          )
      },
      %{
        name: "list_schedules",
        description:
          "The standing instructions in a room: who each one wakes, what it says, and when.",
        inputSchema: object(%{"room" => room_property()})
      },
      %{
        name: "create_schedule",
        description:
          "Wakes a participant at times of day with a message, every day or on chosen " <>
            "weekdays. The message arrives in the room as an ordinary mention and starts a turn.",
        inputSchema:
          object(
            %{
              "participant" => string("Who to wake, by name or id. It must be in the room."),
              "name" => string("A short name for this standing instruction."),
              "prompt" =>
                string(
                  "What to say to it. Written as an instruction for a turn that begins with " <>
                    "no other context than the room."
                ),
              "at" => at_property(),
              "days" => days_property(),
              "room" => room_property(),
              "enabled" => enabled_property()
            },
            ["participant", "name", "prompt", "at"]
          )
      },
      %{
        name: "update_schedule",
        description:
          "Changes a standing instruction, or switches it off. Switching off is how a " <>
            "schedule stops: they are never deleted from here.",
        inputSchema:
          object(
            %{
              "schedule" => string("Which schedule, by id. list_schedules shows them."),
              "name" => string("A short name for this standing instruction."),
              "prompt" => string("What it says."),
              "at" => at_property(),
              "days" => days_property(),
              "room" => room_property(),
              "enabled" => enabled_property()
            },
            ["schedule"]
          )
      },
      %{
        name: "update_profile",
        description:
          "Changes a saved profile. Participants already added from it are their own and stay " <>
            "as they are.",
        inputSchema:
          object(
            %{
              "profile" => string("Which profile, by name or id."),
              "name" => string("A new name for the profile."),
              "provider" => string("Which CLI runs it: #{Enum.join(Agents.ids(), ", ")}."),
              "model" => string("Model id for that provider."),
              "role" => role_property(),
              "cost_tier" => cost_tier_property()
            },
            ["profile"]
          )
      }
    ]
  end

  @doc """
  Runs one tool for the participant that asked for it.

  `{:ok, text}` is what the agent reads back; `{:error, message}` is a sentence
  it can act on — a tool failing is an answer, not a transport error.
  """
  def call(agent, name, args \\ %{})

  def call(_agent, "list_rooms", _args),
    do: {:ok, json(Enum.map(Chat.rooms(), &room_view/1))}

  def call(agent, "list_participants", args) do
    with {:ok, room} <- room(agent, args),
         do: {:ok, json(Enum.map(Chat.agents(room.id), &participant_view/1))}
  end

  def call(_agent, "list_profiles", _args),
    do: {:ok, json(Enum.map(Chat.agent_profiles(), &profile_view/1))}

  def call(_agent, "list_providers", _args),
    do: {:ok, json(Enum.map(Agents.providers(), &Map.put(&1, :models, Agents.models(&1.id))))}

  def call(agent, "create_room", args) do
    attrs = %{
      "name" => args["name"],
      "directory" => args["directory"] || Chat.room!(agent.room_id).directory,
      "context" => args["brief"] || ""
    }

    case Chat.create_room(attrs) do
      {:ok, room} ->
        done(
          agent,
          "created room #{room.id}, #{room.name}, working in #{room.directory}. " <>
            "It has no participants yet."
        )

      {:error, changeset} ->
        {:error, invalid(changeset)}
    end
  end

  def call(agent, "update_room", args) do
    with {:ok, room} <- room(agent, args),
         attrs = take(args, %{"name" => "name", "brief" => "context"}),
         {:ok, updated} <- write(Chat.update_room(room.id, attrs)) do
      done(agent, "updated room #{updated.id}, #{updated.name}: #{changed(attrs)}.")
    end
  end

  def call(agent, "add_participant", args) do
    with :ok <- refuse_approvals(args),
         {:ok, room} <- room(agent, args),
         {:ok, added} <- add(room, args) do
      done(
        agent,
        "added #{added.name} to room #{room.id}, #{room.name}, running on " <>
          "#{added.provider}#{model_suffix(added)}."
      )
    end
  end

  def call(agent, "update_participant", args) do
    with :ok <- refuse_approvals(args),
         {:ok, room} <- room(agent, args),
         {:ok, target} <- participant_in(room, args["participant"]),
         attrs = take(args, participant_fields()),
         {:ok, updated} <- write(Chat.update_agent(target.id, attrs)) do
      done(agent, "updated #{updated.name} in room #{room.id}: #{changed(attrs)}.")
    end
  end

  def call(agent, "create_profile", args) do
    with :ok <- refuse_approvals(args),
         {:ok, profile} <- write(Chat.create_agent_profile(take(args, profile_fields()))) do
      done(
        agent,
        "saved the profile #{profile.name}, running on #{profile.provider}" <>
          "#{model_suffix(profile)}. Add it to a room with add_participant."
      )
    end
  end

  def call(agent, "update_profile", args) do
    with :ok <- refuse_approvals(args),
         {:ok, profile} <- profile(args["profile"]),
         attrs = take(args, profile_fields()),
         {:ok, updated} <- write(Chat.update_agent_profile(profile.id, attrs)) do
      done(agent, "updated the profile #{updated.name}: #{changed(attrs)}.")
    end
  end

  def call(agent, "list_schedules", args) do
    with {:ok, room} <- room(agent, args),
         do: {:ok, json(Enum.map(Chat.schedules(room.id), &schedule_view/1))}
  end

  def call(agent, "create_schedule", args) do
    with {:ok, room} <- room(agent, args),
         {:ok, target} <- participant_in(room, args["participant"]),
         attrs = args |> take(schedule_fields()) |> Map.put("agent_id", target.id),
         {:ok, saved} <- write(Chat.create_schedule(room.id, attrs)) do
      done(
        agent,
        "will wake #{target.name} in room #{room.id}, #{room.name}, at " <>
          "#{Schedule.describe(saved)}, saying: #{saved.prompt}"
      )
    end
  end

  def call(agent, "update_schedule", args) do
    with {:ok, room} <- room(agent, args),
         {:ok, existing} <- schedule_in(room, args["schedule"]),
         attrs = take(args, schedule_fields()),
         {:ok, updated} <- write(Chat.update_schedule(existing.id, attrs)) do
      done(
        agent,
        "changed schedule #{updated.id} in room #{room.id}: #{changed(attrs)}. " <>
          "It now runs at #{Schedule.describe(updated)}#{if updated.enabled, do: "", else: ", switched off"}."
      )
    end
  end

  def call(_agent, name, _args),
    do: {:error, "There is no tool called #{name} here."}

  # Deliberately without auto_approve. Whether a participant stops to ask is the
  # switch that makes every other tool here safe, so it is the human's alone —
  # and a participant that could set it on itself would be past the gate that
  # was watching it.
  defp participant_fields,
    do: %{"name" => "name", "model" => "model", "role" => "role", "cost_tier" => "cost_tier"}

  defp refuse_approvals(args) do
    if Map.has_key?(args, "auto_approve"),
      do:
        {:error,
         "Tool approvals are the human's to set, on the participant's own card or with " <>
           "/auto. They cannot be changed from here."},
      else: :ok
  end

  defp profile_fields, do: Map.put(participant_fields(), "provider", "provider")

  defp schedule_fields,
    do: %{
      "name" => "name",
      "prompt" => "prompt",
      "at" => "at",
      "days" => "days",
      "enabled" => "enabled"
    }

  defp schedule_in(room, reference) when is_binary(reference) or is_integer(reference) do
    wanted = reference |> to_string() |> String.trim()

    case Enum.find(Chat.schedules(room.id), &(to_string(&1.id) == wanted)) do
      nil -> {:error, "#{room.name} has no schedule #{wanted}. list_schedules shows them."}
      schedule -> {:ok, schedule}
    end
  end

  defp schedule_in(room, _reference),
    do: {:error, "Say which schedule in #{room.name} to change, by id."}

  defp add(room, %{"profile" => reference} = args) when is_binary(reference) do
    with {:ok, profile} <- profile(reference),
         do: write(Chat.add_profile_to_room(room.id, profile.id, args["name"]))
  end

  defp add(room, args) do
    attrs =
      args
      |> take(Map.put(participant_fields(), "provider", "provider"))
      |> Map.put_new("provider", "")

    write(Chat.create_agent(room.id, attrs))
  end

  # The human is watching a conversation, not a database, so anything a
  # participant changes about the rooms is said out loud where it was asked for.
  # Never with an "@" in it: that would read as a mention and start a turn.
  defp done(agent, text) do
    Coordinator.post(agent.room_id, String.replace("#{agent.name}: #{text}", "@", ""),
      sender: "system",
      kind: "agent"
    )

    {:ok, text}
  end

  defp room(_agent, %{"room" => reference}) when is_binary(reference) and reference != "" do
    case Chat.find_room(reference) do
      nil -> {:error, "There is no room called #{reference}. list_rooms shows them all."}
      room -> {:ok, room}
    end
  end

  defp room(agent, _args), do: {:ok, Chat.room!(agent.room_id)}

  defp participant_in(room, reference) when is_binary(reference) and reference != "" do
    wanted = String.downcase(String.trim(reference))
    members = Chat.agents(room.id)

    case Enum.find(members, &(&1.name == wanted or to_string(&1.id) == wanted)) do
      nil -> {:error, "#{room.name} has no participant called #{reference}."}
      agent -> {:ok, agent}
    end
  end

  defp participant_in(room, _reference),
    do: {:error, "Say which participant in #{room.name} to change."}

  defp profile(reference) when is_binary(reference) and reference != "" do
    wanted = String.downcase(String.trim(reference))

    case Enum.find(Chat.agent_profiles(), &(&1.name == wanted or to_string(&1.id) == wanted)) do
      nil -> {:error, "There is no profile called #{reference}. list_profiles shows the library."}
      profile -> {:ok, profile}
    end
  end

  defp profile(_reference), do: {:error, "Say which profile to use, by name."}

  # Only what the caller actually sent: a field left out keeps its value rather
  # than being cleared to the JSON default.
  defp take(args, fields) do
    for {given, attribute} <- fields, Map.has_key?(args, given), into: %{} do
      {attribute, args[given]}
    end
  end

  defp changed(attrs) when map_size(attrs) == 0, do: "nothing"
  defp changed(attrs), do: attrs |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp write({:ok, record}), do: {:ok, record}
  defp write({:error, changeset}), do: {:error, invalid(changeset)}

  defp invalid(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp model_suffix(%{model: model}) when is_binary(model) and model != "", do: " (#{model})"
  defp model_suffix(_record), do: ""

  defp room_view(room) do
    %{
      id: room.id,
      name: room.name,
      directory: room.directory,
      brief: room.context,
      participants: Enum.map(Chat.agents(room.id), & &1.name)
    }
  end

  defp participant_view(agent) do
    %{
      id: agent.id,
      name: agent.name,
      provider: agent.provider,
      model: agent.model,
      cost_tier: agent.cost_tier,
      role: agent.role,
      auto_approve: agent.auto_approve
    }
  end

  defp schedule_view(schedule) do
    %{
      id: schedule.id,
      name: schedule.name,
      participant: Chat.agent!(schedule.agent_id).name,
      prompt: schedule.prompt,
      at: schedule.at,
      days: schedule.days,
      when: Schedule.describe(schedule),
      enabled: schedule.enabled,
      last_run_at: schedule.last_run_at
    }
  end

  defp profile_view(profile) do
    %{
      id: profile.id,
      name: profile.name,
      provider: profile.provider,
      model: profile.model,
      cost_tier: profile.cost_tier,
      role: profile.role,
      auto_approve: profile.auto_approve
    }
  end

  defp json(data), do: Jason.encode!(data, pretty: true)

  defp serving?, do: Phoenix.Endpoint.server?(:roundtable, RoundtableWeb.Endpoint)

  defp object(properties, required \\ []),
    do: %{
      type: "object",
      properties: properties,
      required: required,
      additionalProperties: false
    }

  defp string(description), do: %{type: "string", description: description}

  defp room_property,
    do: string("Which room, by name, slug or id. Defaults to the room you are in.")

  defp brief_property,
    do:
      string(
        "What this team is doing and how it works. Every participant in the room is given it " <>
          "at the start of every turn."
      )

  defp at_property,
    do:
      string(
        "Times of day it runs at, as HH:MM, separated by commas: \"09:00\" or " <>
          "\"09:00,17:30\". The machine's own local time."
      )

  defp days_property,
    do:
      string(
        "Weekdays it runs on, 1 for Monday through 7 for Sunday: \"1,2,3,4,5\" for " <>
          "weekdays. Leave it out for every day."
      )

  defp enabled_property,
    do: %{type: "boolean", description: "Whether it runs at all. Switch it off to stop it."}

  defp role_property,
    do:
      string(
        "The standing brief for this participant: what it is for and how it should work here."
      )

  defp cost_tier_property,
    do: %{
      type: "string",
      enum: ["economy", "standard", "premium", "unknown"],
      description: "A planning hint about relative cost. Not a verified price."
    }
end
