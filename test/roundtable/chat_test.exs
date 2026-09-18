defmodule Roundtable.ChatTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Repo}
  alias Roundtable.Chat.{Agent, Run}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Build", "directory" => File.cwd!()})

    {:ok, ada} =
      Chat.create_agent(room.id, %{
        "name" => "ada",
        "provider" => "codex",
        "directory" => File.cwd!()
      })

    {:ok, linus} =
      Chat.create_agent(room.id, %{
        "name" => "linus",
        "provider" => "claude",
        "directory" => File.cwd!()
      })

    %{room: room, ada: ada, linus: linus}
  end

  test "mentions queue exactly one delivery and plain chat doesn't wake agents", %{
    room: room,
    ada: ada
  } do
    assert {:ok, _} = Chat.post(room.id, "Just keeping everyone informed.")
    assert Chat.runs(room.id) == []
    assert {:ok, message} = Chat.post(room.id, "@Ada please review this, @ada.")
    assert [%{agent_id: id, message_id: mid, status: "queued"}] = Chat.runs(room.id)
    assert id == ada.id and mid == message.id
  end

  test "room boundaries, email addresses, and sender exclusion", %{
    room: room,
    ada: ada,
    linus: linus
  } do
    {:ok, _} = Chat.post(room.id, "Email hello@ada.example")
    assert Chat.runs(room.id) == []

    {:ok, _} =
      Chat.post(room.id, "@all review", sender: "ada", agent_id: ada.id, kind: "agent", depth: 1)

    assert [%{agent_id: id}] = Chat.runs(room.id)
    assert id == linus.id
    {:ok, other} = Chat.create_room(%{"name" => "Other", "directory" => File.cwd!()})
    Chat.post(other.id, "@ada review")
    assert Chat.runs(other.id) == []
  end

  test "four-hop delegation cap retains the message but stops automatic work", %{room: room} do
    {:ok, message} = Chat.post(room.id, "@all keep talking", kind: "agent", depth: 4)
    assert Chat.runs(room.id) == []
    assert Enum.any?(Chat.messages(room.id), &(&1.id == message.id))
  end

  test "new sessions receive history and resumed sessions receive unread context", %{
    room: room,
    ada: ada
  } do
    {:ok, old} = Chat.post(room.id, "Remember the chosen API design")
    {:ok, assigned} = Chat.post(room.id, "@ada implement it")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: assigned.id)
    {prompt, last_id} = Chat.prompt(ada, run)
    assert prompt =~ old.body
    assert last_id == assigned.id
    ada = Chat.change(ada, last_seen_id: old.id, session_id: "test-session")
    {prompt, _} = Chat.prompt(ada, run)
    refute prompt =~ old.body
    assert prompt =~ assigned.body
  end

  test "a turn opens with who the participant is and the brief it works to", %{
    room: room,
    ada: ada
  } do
    ada = Chat.change(ada, role: "Review changes, never write them")
    {:ok, assigned} = Chat.post(room.id, "@ada take a look")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: assigned.id)
    {prompt, _} = Chat.prompt(ada, run)

    assert String.starts_with?(prompt, "You are @ada in Roundtable")
    assert prompt =~ "Your role: Review changes, never write them"
    assert prompt =~ "governs every turn you take here"

    # Identity and brief come before the details of this one assignment.
    [_, identity, assignment] =
      Regex.run(~r/(WHO YOU ARE AND HOW YOU WORK).*(THIS ASSIGNMENT)/s, prompt)

    assert :binary.match(prompt, identity) < :binary.match(prompt, assignment)
  end

  test "the room's brief reaches every participant's turn", %{room: room, ada: ada} do
    {:ok, _} =
      Chat.update_room(room.id, %{
        "context" => "Elixir and Phoenix. Tests with every change, mix precommit before done."
      })

    {:ok, assigned} = Chat.post(room.id, "@ada take a look")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: assigned.id)
    {prompt, _} = Chat.prompt(ada, run)

    assert prompt =~ "THIS ROOM"
    assert prompt =~ "Tests with every change, mix precommit before done."
    assert prompt =~ "shared brief for everyone here"

    # A room keeps its tree: the brief is not a way to move everyone elsewhere.
    {:ok, _} = Chat.update_room(room.id, %{"directory" => "/tmp", "name" => "Build"})
    assert Chat.room!(room.id).directory == room.directory
  end

  test "a room with no brief says so rather than leaving a blank", %{room: room, ada: ada} do
    {:ok, assigned} = Chat.post(room.id, "@ada take a look")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: assigned.id)
    {prompt, _} = Chat.prompt(ada, run)

    assert prompt =~ "No shared brief has been set for this room"
  end

  test "a participant with no role is told that, not given an invented one", %{
    room: room,
    ada: ada
  } do
    {:ok, assigned} = Chat.post(room.id, "@ada take a look")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: assigned.id)
    {prompt, _} = Chat.prompt(ada, run)

    assert prompt =~ "No role has been set for you"
    assert prompt =~ "what you would need to be more useful"
  end

  test "a session given one brief is told when it has been replaced", %{room: room, ada: ada} do
    {:ok, assigned} = Chat.post(room.id, "@ada take a look")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: assigned.id)

    changed =
      Chat.change(ada,
        session_id: "native",
        session_role: "Write the API",
        role: "Review changes only"
      )

    {prompt, _} = Chat.prompt(changed, run)
    assert prompt =~ "Your role changed since your last turn. It used to be: Write the API"

    # Nothing to announce while the brief is the one the session was given.
    same = Chat.change(changed, session_role: "Review changes only")
    {prompt, _} = Chat.prompt(same, run)
    refute prompt =~ "Your role changed"

    # Nor on a fresh session, which hears the current role and nothing else.
    fresh = Chat.change(changed, session_id: nil)
    {prompt, _} = Chat.prompt(fresh, run)
    refute prompt =~ "Your role changed"
  end

  test "a profile is a template: adding it creates a participant of its own", %{room: room} do
    {:ok, profile} =
      Chat.create_agent_profile(%{
        "name" => "reviewer",
        "provider" => "claude",
        "model" => "sonnet",
        "cost_tier" => "standard",
        "role" => "Review diffs. Say what is wrong, do not fix it.",
        "auto_approve" => true
      })

    {:ok, agent} = Chat.add_profile_to_room(room.id, profile.id)

    assert agent.name == "reviewer"
    assert agent.provider == "claude"
    assert agent.model == "sonnet"
    assert agent.role == "Review diffs. Say what is wrong, do not fix it."
    assert agent.auto_approve
    # A room's tree, not the profile's idea of one.
    assert agent.directory == room.directory

    # The same profile can be in a room twice under another name.
    {:ok, second} = Chat.add_profile_to_room(room.id, profile.id, "reviewer-api")
    assert second.name == "reviewer-api"
    refute second.id == agent.id

    # Changing the profile afterwards leaves the participants alone.
    {:ok, _} = Chat.update_agent_profile(profile.id, %{"role" => "Something else entirely"})
    assert Chat.agent!(agent.id).role == "Review diffs. Say what is wrong, do not fix it."

    # And so does deleting it.
    {:ok, _} = Chat.delete_agent_profile(profile.id)
    assert Chat.agent_profiles() == []
    assert Chat.agent!(agent.id).name == "reviewer"
  end

  test "a profile is checked before it can be saved" do
    assert {:error, _} =
             Chat.create_agent_profile(%{"name" => "Not Valid", "provider" => "codex"})

    assert {:error, _} = Chat.create_agent_profile(%{"name" => "ok", "provider" => "nope"})
    {:ok, _} = Chat.create_agent_profile(%{"name" => "twice", "provider" => "codex"})
    assert {:error, _} = Chat.create_agent_profile(%{"name" => "twice", "provider" => "codex"})
  end

  test "invalid directories and duplicate names are rejected", %{room: room} do
    assert {:error, _} =
             Chat.create_room(%{"name" => "Invalid", "directory" => "/does-not-exist-roundtable"})

    assert {:error, _} =
             Chat.create_agent(room.id, %{
               "name" => "ADA",
               "provider" => "codex",
               "directory" => File.cwd!()
             })

    assert {:error, _} =
             Chat.create_agent(room.id, %{
               "name" => "you",
               "provider" => "codex",
               "directory" => File.cwd!()
             })

    assert {:error, _} =
             Chat.create_agent(room.id, %{
               "name" => "custom",
               "provider" => "unknown",
               "directory" => File.cwd!()
             })
  end

  test "nobody is called schedule, because the scheduler already is", %{room: room} do
    # Its messages are signed "schedule"; a participant of that name would be
    # indistinguishable from the room's own standing instructions.
    assert {:error, changeset} =
             Chat.create_agent(room.id, %{
               "name" => "schedule",
               "provider" => "codex",
               "directory" => File.cwd!()
             })

    assert "is reserved" in errors_on(changeset).name

    assert {:error, _} =
             Chat.create_agent_profile(%{"name" => "schedule", "provider" => "codex"})
  end

  test "recovery marks active turns interrupted and keeps sessions and pending deliveries", %{
    room: room,
    ada: ada
  } do
    Chat.change(ada, session_id: "saved-session")
    Chat.post(room.id, "@ada first")
    [run] = Chat.runs(room.id)
    Chat.change(run, status: "running", output: "partial output")
    Chat.post(room.id, "@ada second")
    Chat.recover()
    assert Repo.get!(Run, run.id).status == "interrupted"
    assert Repo.get!(Run, run.id).output == "partial output"
    assert Repo.get!(Agent, ada.id).session_id == "saved-session"
    assert Enum.any?(Chat.runs(room.id), &(&1.status == "queued"))
  end

  test "model choices are snapshotted and all agents receive cost context", %{
    room: room,
    ada: ada,
    linus: linus
  } do
    Chat.change(linus, model: "review-model", cost_tier: "premium")

    {:ok, preset} =
      Chat.create_model_preset(%{
        "name" => "Routine tasks",
        "provider" => "codex",
        "model" => "economy-model",
        "cost_tier" => "economy"
      })

    {:ok, options} = Chat.assignment(ada, to_string(preset.id), "implementation")
    {:ok, message} = Chat.post(room.id, "@ada implement it", assignment: options)
    [run] = Chat.runs(room.id)
    assert run.model == "economy-model"
    assert run.cost_tier == "economy"
    assert run.purpose == "implementation"
    assert message.metadata["cost_tier"] == "economy"

    Chat.update_model_preset(preset.id, %{"model" => "different-model", "cost_tier" => "standard"})

    assert Repo.get!(Run, run.id).model == "economy-model"
    {prompt, _} = Chat.prompt(ada, run)
    assert prompt =~ "relative cost=premium"
    assert prompt =~ "review-model"
    assert prompt =~ "Relative cost tier: economy"
    assert {:error, _} = Chat.assignment(linus, to_string(preset.id), "verification")
    assert {:error, _} = Chat.assignment(ada, "999999", "general")
  end

  test "a new model reaches work already waiting, and the session it would resume", %{
    room: room,
    ada: ada
  } do
    Chat.change(ada, model: "old-model", session_id: "native", session_model: "old-model")
    {:ok, _} = Chat.post(room.id, "@ada one")
    {:ok, _} = Chat.post(room.id, "@ada two")

    {:ok, _} = Chat.update_agent(ada.id, %{"model" => "new-model"})

    assert Enum.all?(Chat.runs(room.id), &(&1.model == "new-model"))
    # The provider would otherwise carry on with the model the session began on.
    assert Chat.agent!(ada.id).session_id == nil
    assert Chat.agent!(ada.id).session_model == nil
  end

  test "a model chosen for one turn survives a later change of default", %{room: room, ada: ada} do
    {:ok, preset} =
      Chat.create_model_preset(%{
        "name" => "Planning",
        "provider" => "codex",
        "model" => "premium-model",
        "cost_tier" => "premium"
      })

    {:ok, options} = Chat.assignment(ada, to_string(preset.id), "planning")
    {:ok, _} = Chat.post(room.id, "@ada plan", assignment: options)

    {:ok, _} = Chat.update_agent(ada.id, %{"model" => "new-model"})

    [run] = Chat.runs(room.id)
    assert run.model_pinned
    assert run.model == "premium-model"
  end

  test "changing something other than the model leaves the session alone", %{ada: ada} do
    Chat.change(ada, session_id: "native", session_model: nil)
    {:ok, _} = Chat.update_agent(ada.id, %{"role" => "review only"})

    assert Chat.agent!(ada.id).session_id == "native"
  end

  test "the roster tells each agent who is busy", %{room: room, ada: ada} do
    {:ok, message} = Chat.post(room.id, "@ada start")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: message.id)

    {prompt, _} = Chat.prompt(ada, run)
    assert prompt =~ "@ada: provider=codex"
    assert prompt =~ "@linus: provider=claude"
    assert prompt =~ "status=idle"

    # A queued turn counts as busy: the work is already assigned.
    Chat.change(run, status: "queued")
    {prompt, _} = Chat.prompt(ada, run)
    assert prompt =~ ~r/@ada:.*status=queued/
    assert prompt =~ ~r/@linus:.*status=idle/

    Chat.change(run, status: "running")
    {prompt, _} = Chat.prompt(ada, run)
    assert prompt =~ ~r/@ada:.*status=running/
  end

  test "models come from the CLI where it can say, and are never invented" do
    alias Roundtable.Agents

    # Claude Code has no listing command; these are the aliases its --help names.
    assert Agents.models("claude") == ["fable", "opus", "sonnet"]

    # Codex has neither a listing nor documented aliases, so nothing is offered.
    assert Agents.models("codex") == []
    assert Agents.models("nonsense") == []

    # OpenCode can list, so whatever it reports is what we offer.
    opencode = Agents.models("opencode")
    assert is_list(opencode)
    assert Enum.all?(opencode, &is_binary/1)
    refute Enum.any?(opencode, &(&1 == ""))
  end

  test "a participant is put in its room's directory, whatever it was given", %{room: room} do
    other = Path.join(System.tmp_dir!(), "somewhere-else-#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "grace",
        "provider" => "opencode",
        "directory" => other
      })

    assert agent.directory == room.directory
    refute agent.directory == other
  end
end
