defmodule Roundtable.PromptTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.Chat
  alias Roundtable.Chat.Run

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Build", "directory" => File.cwd!()})

    {:ok, agent} =
      Chat.create_agent(room.id, %{
        "name" => "developer",
        "provider" => "codex",
        "directory" => File.cwd!(),
        "role" => "Implement changes. Never push; ship tests and documentation."
      })

    {:ok, task} = Chat.post(room.id, "@developer implement the task")
    run = Repo.get_by!(Run, message_id: task.id, agent_id: agent.id)

    resumed = %{
      agent
      | session_id: "native",
        instruction_turns: 0,
        session_model: run.model,
        session_role: agent.role,
        session_directory: agent.directory
    }

    %{room: room, agent: agent, resumed: resumed, run: run, task: task}
  end

  test "fresh sessions get full rules and resumed sessions retain dynamic context", ctx do
    {fresh, _} = Chat.prompt(ctx.agent, ctx.run)
    {resumed, _} = Chat.prompt(ctx.resumed, ctx.run)

    for rule <- [
          "WHO YOU ARE AND HOW YOU WORK",
          "Cost tiers are human-provided",
          "To delegate,",
          "THE ROOMS THEMSELVES"
        ] do
      assert fresh =~ rule
      refute resumed =~ rule
    end

    assert fresh =~ ctx.agent.role
    refute resumed =~ "Never push; ship tests and documentation."
    assert resumed =~ "Earlier standing instructions still apply"
    assert resumed =~ "SHARED WORK DOCUMENT"
    assert resumed =~ "provider=codex"
    assert resumed =~ "usage=not reported"
    assert resumed =~ ctx.task.body
  end

  test "resumed turns carry changed roles, briefs and roster membership", ctx do
    {:ok, _} = Chat.update_room(ctx.room.id, %{"context" => "New room conventions"})
    changed = %{ctx.resumed | role: "Review only. Never modify code."}
    {prompt, _} = Chat.prompt(changed, ctx.run)
    assert prompt =~ "Your role: Review only. Never modify code."
    assert prompt =~ "Your role changed since your last turn."
    assert prompt =~ "New room conventions"

    {:ok, peer} =
      Chat.create_agent(ctx.room.id, %{
        "name" => "reviewer",
        "provider" => "claude",
        "directory" => File.cwd!()
      })

    {prompt, _} = Chat.prompt(changed, ctx.run)
    assert prompt =~ "@reviewer: provider=claude"
    Chat.delete_agent(peer.id)
    {prompt, _} = Chat.prompt(changed, ctx.run)
    refute prompt =~ "@reviewer:"

    {prompt, _} = Chat.prompt(%{changed | role: ""}, ctx.run)
    assert prompt =~ "No role has been set for you"
  end

  test "missing session snapshots, resets, model and folder changes restore full rules", ctx do
    for agent <- [
          %{ctx.resumed | session_id: nil},
          %{ctx.resumed | session_role: nil},
          %{ctx.resumed | session_model: "older-model"},
          %{ctx.resumed | session_directory: "/old-folder"}
        ] do
      {prompt, _} = Chat.prompt(agent, ctx.run)
      assert prompt =~ "WHO YOU ARE AND HOW YOU WORK"
      assert prompt =~ "THE ROOMS THEMSELVES"
      assert prompt =~ ctx.agent.role
    end
  end

  test "quota retries restore rules even when continuing the same provider session", ctx do
    run = %{ctx.run | retry_count: 1, retry_context: "Already changed the parser."}
    {prompt, _} = Chat.prompt(ctx.resumed, run)
    assert prompt =~ "WHO YOU ARE AND HOW YOU WORK"
    assert prompt =~ "RESUMING AFTER A QUOTA WAIT"
    assert prompt =~ "Already changed the parser."
  end

  test "filter noise before budgeting, retain peer history and advance the cursor", ctx do
    {:ok, peer} = Chat.post(ctx.room.id, "Useful peer result", sender: "reviewer", kind: "agent")

    {:ok, _} =
      Chat.post(ctx.room.id, String.duplicate("noise", 12_500), sender: "system", kind: "system")

    {:ok, own} =
      Chat.post(ctx.room.id, "My earlier answer",
        sender: ctx.agent.name,
        kind: "agent",
        agent_id: ctx.agent.id
      )

    for agent <- [
          ctx.agent,
          ctx.resumed,
          %{ctx.resumed | session_id: nil, last_seen_id: 0},
          %{ctx.resumed | instruction_turns: 20}
        ] do
      {prompt, cursor} = Chat.prompt(agent, ctx.run)
      assert prompt =~ peer.body
      refute prompt =~ "noise"
      assert prompt =~ own.body == is_nil(agent.session_id)
      refute prompt =~ "oldest unread messages"
      assert cursor == own.id
    end

    {prompt, _} = Chat.prompt(ctx.resumed, %{ctx.run | message_id: own.id})
    assert prompt =~ "Assigned message #{own.id} from developer:\nMy earlier answer"
  end

  test "roster roles stop at the first sentence or 120 characters on one line", ctx do
    for {role, expected} <- [
          {"Review code. Also write reports.", "Review code."},
          {"Review code!\nAlso write reports.", "Review code!"},
          {String.duplicate("x", 150), String.duplicate("x", 120)},
          {"Review\ncode without a sentence", "Review code without a sentence"}
        ] do
      Chat.change(ctx.agent, role: role)
      {prompt, _} = Chat.prompt(ctx.resumed, ctx.run)
      assert prompt =~ "usage=not reported, role=#{expected}\n"
    end
  end
end
