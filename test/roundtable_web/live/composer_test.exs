defmodule RoundtableWeb.ComposerTest do
  use RoundtableWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Roundtable.{Chat, Coordinator, Repo}
  alias Roundtable.Chat.Run

  setup %{conn: conn} do
    {:ok, room} = Chat.create_room(%{name: "Composer", directory: File.cwd!()})
    {:ok, agent} = Chat.create_agent(room.id, %{name: "ada", provider: "claude"})
    {:ok, view, _} = live(conn, "/rooms/#{room.id}")
    %{room: room, agent: agent, view: view}
  end

  test "auto, model and role update the participant without posting messages", ctx do
    submit(ctx.view, "/auto ada on")
    assert Chat.agent!(ctx.agent.id).auto_approve
    submit(ctx.view, "/auto ada off")
    refute Chat.agent!(ctx.agent.id).auto_approve
    submit(ctx.view, "/model ada chosen-model")
    assert Chat.agent!(ctx.agent.id).model == "chosen-model"
    submit(ctx.view, "/model ada default")
    assert Chat.agent!(ctx.agent.id).model == nil
    submit(ctx.view, "/role ada Review changes and keep notes")
    assert Chat.agent!(ctx.agent.id).role == "Review changes and keep notes"
    assert Chat.messages(ctx.room.id) == []
    assert Chat.runs(ctx.room.id) == []
  end

  test "rename uses existing validation and refuses renaming after a turn", ctx do
    submit(ctx.view, "/rename ada grace")
    assert Chat.agent!(ctx.agent.id).name == "grace"
    submit(ctx.view, "/rename grace invalid!")
    assert has_element?(ctx.view, "[role=alert]", "Update the command")
    assert Chat.agent!(ctx.agent.id).name == "grace"
    Chat.post(ctx.room.id, "@grace work")
    submit(ctx.view, "/rename grace newname")
    assert has_element?(ctx.view, "[role=alert]", "cannot change")
    assert Chat.agent!(ctx.agent.id).name == "grace"
  end

  test "reset clears the session and preserves history", ctx do
    Chat.change(ctx.agent, session_id: "old-session")
    {:ok, message} = Chat.post(ctx.room.id, "Keep this note")
    submit(ctx.view, "/reset ada")
    assert Chat.agent!(ctx.agent.id).session_id == nil
    assert Enum.any?(Chat.messages(ctx.room.id), &(&1.id == message.id))
  end

  test "remove requires confirmation, can be cancelled, and keeps messages", ctx do
    {:ok, message} =
      Chat.post(ctx.room.id, "Work done", kind: "agent", agent_id: ctx.agent.id, sender: "ada")

    submit(ctx.view, "/remove ada")
    assert has_element?(ctx.view, "#confirm-remove-agent")
    assert Chat.agent!(ctx.agent.id)
    ctx.view |> element("#cancel-remove-agent") |> render_click()
    assert Chat.agent!(ctx.agent.id)
    submit(ctx.view, "/remove ada")
    ctx.view |> element("#confirm-remove-agent") |> render_click()
    assert Chat.agents(ctx.room.id) == []
    assert Enum.any?(Chat.messages(ctx.room.id), &(&1.id == message.id))
  end

  test "who opens a roster and the composer advertises all new commands", ctx do
    submit(ctx.view, "/who")
    assert has_element?(ctx.view, "#command-roster #roster-agent-#{ctx.agent.id}", "ada")

    for name <- ~w(auto model role reset retry approve rename remove who) do
      assert has_element?(ctx.view, "#message-form[data-commands*='\"name\":\"#{name}\"']")
    end

    assert Chat.messages(ctx.room.id) == []
  end

  test "each command rejects bad input without posting a chat message", ctx do
    for body <- [
          "/auto ada yes",
          "/model absent default",
          "/role ada",
          "/reset absent",
          "/retry invalid",
          "/approve accept 0",
          "/rename absent new",
          "/remove absent",
          "/who extra"
        ] do
      submit(ctx.view, body)
      assert has_element?(ctx.view, "[role=alert]"), body
    end

    assert Chat.messages(ctx.room.id) == []
    assert Chat.agents(ctx.room.id) == [ctx.agent]
  end

  test "retry selects a failed room run, defaults to newest and cannot reach another room", ctx do
    {:ok, _} = Chat.post(ctx.room.id, "@ada work")
    [run] = Chat.runs(ctx.room.id)
    Chat.change(run, status: "failed")
    Chat.broadcast(ctx.room.id)
    submit(ctx.view, "/retry")
    assert Repo.get!(Run, run.id).status == "queued"
    Chat.change(run, status: "failed")
    Chat.broadcast(ctx.room.id)
    submit(ctx.view, "/retry #{run.id}")
    assert Repo.get!(Run, run.id).status == "queued"

    {:ok, other} = Chat.create_room(%{name: "Other", directory: File.cwd!()})
    {:ok, _} = Chat.create_agent(other.id, %{name: "bob", provider: "claude"})
    Chat.post(other.id, "@bob work")
    [foreign] = Chat.runs(other.id)
    Chat.change(foreign, status: "failed")
    submit(ctx.view, "/retry #{foreign.id}")
    assert has_element?(ctx.view, "[role=alert]", "No matching run")
    assert Repo.get!(Run, foreign.id).status == "failed"
  end

  test "approve accepts and declines the numbered request through the coordinator", ctx do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    Coordinator.post(ctx.room.id, "@ada work")
    assert_receive {:agent_started, _, _, run, _}, 1000
    Coordinator.event(run.id, {:approval, "b", %{"command" => "second"}})
    Coordinator.event(run.id, {:approval, "a", %{"command" => "first"}})
    assert has_element?(ctx.view, "#approval-#{run.id}-a", "approval 1")
    assert has_element?(ctx.view, "#approval-#{run.id}-b", "approval 2")
    submit(ctx.view, "/approve decline 2")
    assert_receive {:decision, "b", "decline"}, 1000
    submit(ctx.view, "/approve accept")
    assert_receive {:decision, "a", "accept"}, 1000
    assert Coordinator.approvals() == %{}
    Coordinator.stop(ctx.agent.id)
  end

  defp submit(view, body),
    do: view |> form("#message-form", message: %{body: body}) |> render_submit()
end
