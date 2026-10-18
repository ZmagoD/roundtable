defmodule Roundtable.ProviderSwitchTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator, FakeCLIs, Repo}
  alias Roundtable.Chat.Run

  setup do
    Application.put_env(:roundtable, :agent_worker, Roundtable.TestWorker)
    Application.put_env(:roundtable, :test_observer, self())
    Application.put_env(:roundtable, :start_agents, true)
    cleanup = FakeCLIs.install(["claude", "codex", "opencode"])

    on_exit(fn ->
      cleanup.()
      Application.put_env(:roundtable, :start_agents, false)
      Application.delete_env(:roundtable, :agent_worker)
      Application.delete_env(:roundtable, :test_observer)
    end)

    {:ok, room} = Chat.create_room(%{name: "Switching", directory: File.cwd!()})

    {:ok, ada} =
      Chat.create_agent(room.id, %{name: "ada", provider: "claude", role: "Review changes"})

    %{room: room, ada: ada}
  end

  defp finish_turn(room, text) do
    Coordinator.post(room.id, text)
    assert_receive {:agent_started, pid, agent, run, prompt}, 1000
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, "Done."})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Coordinator)
    {agent, run, prompt}
  end

  test "Claude to Codex keeps identity and drops the native session", %{room: room, ada: ada} do
    Chat.set_team_head(ada.id)
    finish_turn(room, "@ada first task")
    assert Chat.agent!(ada.id).session_id

    assert {:ok, switched} =
             Chat.update_agent(ada.id, %{"provider" => "codex", "model" => "gpt-x"})

    assert switched.id == ada.id
    assert switched.name == "ada"
    assert switched.role == "Review changes"
    assert switched.head
    assert switched.provider == "codex"
    assert switched.session_id == nil
    assert switched.context_handover
    assert length(Chat.messages(room.id)) >= 2
  end

  test "the next turn after a switch carries a handover, once", %{room: room, ada: ada} do
    finish_turn(room, "@ada remember that the cart total rounds half up")
    {:ok, _} = Chat.update_agent(ada.id, %{"provider" => "codex"})
    assert Repo.aggregate(Run, :count) == 1

    {agent, _run, prompt} = finish_turn(room, "@ada carry on")

    assert agent.provider == "codex"
    assert prompt =~ "Context handover"
    assert prompt =~ "not transferred"
    assert prompt =~ "cart total rounds half up"
    assert prompt =~ "carry on"

    {_, _, later} = finish_turn(room, "@ada and again")
    refute later =~ "Context handover"
  end

  test "Codex back to Claude does the same" do
    {:ok, room} = Chat.create_room(%{name: "Reverse", directory: File.cwd!()})
    {:ok, bob} = Chat.create_agent(room.id, %{name: "bob", provider: "codex"})
    finish_turn(room, "@bob plan the tax work")
    {:ok, _} = Chat.update_agent(bob.id, %{"provider" => "claude", "model" => "opus"})

    {agent, _run, prompt} = finish_turn(room, "@bob go")
    assert {agent.provider, Chat.agent!(bob.id).model} == {"claude", "opus"}
    assert prompt =~ "plan the tax work"
    assert prompt =~ "Context handover"
  end

  test "a model-only change keeps the provider and moves queued work", %{room: room, ada: ada} do
    {:ok, _} = Chat.post(room.id, "@ada queued one")
    {:ok, _} = Chat.update_agent(ada.id, %{"model" => "opus"})

    assert Chat.agent!(ada.id).provider == "claude"
    assert Enum.all?(Chat.runs(room.id), &(&1.model == "opus"))
  end

  test "an unknown, uninstalled or unlisted choice is refused and nothing changes", %{ada: ada} do
    assert {:error, cs} = Chat.update_agent(ada.id, %{"provider" => "nonesuch"})
    assert %{provider: [_ | _]} = errors_on(cs)

    assert Chat.agent!(ada.id).provider == "claude"

    assert {:error, cs} =
             Chat.update_agent(ada.id, %{
               "provider" => "opencode",
               "model" => "not-listed",
               "auto_approve" => true
             })

    assert %{model: [_ | _]} = errors_on(cs)
    assert Chat.agent!(ada.id).provider == "claude"
  end

  test "a listed model from the CLI is accepted", %{ada: ada} do
    assert {:ok, %{provider: "opencode", model: "ollama/qwen3:8b"}} =
             Chat.update_agent(ada.id, %{
               "provider" => "opencode",
               "model" => "ollama/qwen3:8b",
               "auto_approve" => true
             })
  end

  test "a provider without approval support is not switched to silently", %{ada: ada} do
    assert {:error, cs} = Chat.update_agent(ada.id, %{"provider" => "opencode"})
    assert %{provider: [message]} = errors_on(cs)
    assert message =~ "automatic approval"
    assert Chat.agent!(ada.id).auto_approve == false
  end

  test "a provider switch is refused while a turn runs, and a model change leaves it be", %{
    room: room,
    ada: ada
  } do
    Coordinator.post(room.id, "@ada long task")
    assert_receive {:agent_started, _pid, _, run, _}, 1000

    assert {:error, cs} = Chat.update_agent(ada.id, %{"provider" => "codex"})
    assert %{provider: [_ | _]} = errors_on(cs)
    assert Chat.agent!(ada.id).provider == "claude"

    assert {:ok, _} = Chat.update_agent(ada.id, %{"model" => "opus"})
    assert Repo.get!(Run, run.id).status == "running"
    Coordinator.stop(ada.id)
  end

  test "a provider switch is refused with work queued or waiting for quota", %{
    room: room,
    ada: ada
  } do
    {:ok, _} = Chat.post(room.id, "@ada queued")
    assert {:error, _} = Chat.update_agent(ada.id, %{"provider" => "codex"})

    [run] = Chat.runs(room.id)
    Chat.change(run, status: "waiting_quota")
    assert {:error, _} = Chat.update_agent(ada.id, %{"provider" => "codex"})
    assert Chat.agent!(ada.id).provider == "claude"
  end

  test "a queued turn pinned to another provider's model is failed, not sent", %{room: room} do
    {:ok, _} = Chat.post(room.id, "@ada pinned")
    [run] = Chat.runs(room.id)
    Chat.change(run, provider: "codex", model: "gpt-pinned", model_pinned: true)

    Coordinator.retry(run.id)
    _ = :sys.get_state(Coordinator)

    refute_received {:agent_started, _, _, _, _}
    failed = Repo.get!(Run, run.id)
    assert failed.status == "failed"
    assert failed.error =~ "another provider"
  end

  test "saving a switch starts no turn", %{ada: ada} do
    {:ok, _} = Chat.update_agent(ada.id, %{"provider" => "codex"})
    refute_receive {:agent_started, _, _, _, _}, 100
    assert Repo.aggregate(Run, :count) == 0
  end

  test "identity, name and instructions survive repeated switches", %{ada: ada} do
    {:ok, _} = Chat.update_agent(ada.id, %{"provider" => "codex"})
    {:ok, back} = Chat.update_agent(ada.id, %{"provider" => "claude"})
    assert {back.id, back.name, back.role} == {ada.id, "ada", "Review changes"}
  end
end
