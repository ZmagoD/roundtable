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

  test "the roster names a directory only when it differs from the room's", %{
    room: room,
    ada: ada
  } do
    {:ok, message} = Chat.post(room.id, "@ada start")
    run = Repo.get_by!(Run, agent_id: ada.id, message_id: message.id)

    # Everyone shares the room's directory, so repeating it says nothing.
    {prompt, _} = Chat.prompt(ada, run)
    refute prompt =~ "directory="

    worktree =
      Path.join(System.tmp_dir!(), "roundtable-worktree-#{System.unique_integer([:positive])}")

    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(worktree) end)

    {:ok, _} =
      Chat.create_agent(room.id, %{
        "name" => "grace",
        "provider" => "opencode",
        "directory" => worktree
      })

    {prompt, _} = Chat.prompt(ada, run)
    assert prompt =~ "@grace: provider=opencode"
    assert prompt =~ "directory=#{worktree}"

    refute prompt =~
             "@ada: provider=codex, model=provider default, relative cost=unknown, status=running, directory="
  end
end
