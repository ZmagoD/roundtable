defmodule Roundtable.WatchdogTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, Coordinator, Repo, Supervision}
  alias Roundtable.Chat.{Message, Run}

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Watched", "directory" => File.cwd!()})

    [lead, dev] =
      for name <- ~w(lead dev) do
        {:ok, agent} =
          Chat.create_agent(room.id, %{
            "name" => name,
            "provider" => "codex",
            "directory" => File.cwd!()
          })

        agent
      end

    Chat.clear_team_head(room.id)
    now = DateTime.utc_now(:second)
    %{room: room, lead: lead, dev: dev, now: now}
  end

  defp ended(agent, attrs) do
    # Posted as an agent so a team head is not handed it as well.
    {:ok, message} = Chat.post(agent.room_id, "some work", sender: "system", kind: "agent")

    Repo.insert!(
      struct(
        %Run{agent_id: agent.id, message_id: message.id, status: "failed"},
        Keyword.merge([updated_at: DateTime.add(DateTime.utc_now(:second), -600, :second)], attrs)
      )
    )
  end

  defp notices(room),
    do: Repo.all(from m in Message, where: m.room_id == ^room.id and m.sender == "supervisor")

  defp runs_for(agent), do: Repo.all(from r in Run, where: r.agent_id == ^agent.id)

  test "a crashed turn is queued again and the room is told, without waking anyone", ctx do
    run = ended(ctx.dev, error: "Agent process exited: :killed")
    Coordinator.supervise(ctx.now)

    run = Repo.get!(Run, run.id)
    assert run.status == "queued"
    assert run.supervised_retries == 1
    assert [notice] = notices(ctx.room)
    assert notice.body =~ "dev stopped"
    refute notice.body =~ "@"
    assert runs_for(ctx.lead) == []
  end

  # A crash stops the turns queued behind it. They must neither hide the crash
  # from the watchdog nor be lost: they go back in the queue with it.
  test "a crash with turns queued behind it is still restarted, and they follow", ctx do
    crashed = ended(ctx.dev, status: "interrupted", error: "Agent process exited: :killed")
    held = ended(ctx.dev, status: "stopped", error: Supervision.held_back())
    Coordinator.supervise(ctx.now)

    assert Repo.get!(Run, crashed.id).status == "queued"
    assert Repo.get!(Run, held.id).status == "queued"
    assert [_notice] = notices(ctx.room)
  end

  test "a turn the human stopped still hides an older failure", ctx do
    ended(ctx.dev, error: "boom")

    stopped =
      ended(ctx.dev, status: "stopped", error: "Stopped. Retry to continue this assignment.")

    Coordinator.supervise(ctx.now)
    assert Repo.get!(Run, stopped.id).status == "stopped"
    assert notices(ctx.room) == []
  end

  test "a turn that just failed is left to back off first", ctx do
    run = ended(ctx.dev, error: "connection reset", updated_at: ctx.now)
    Coordinator.supervise(ctx.now)
    assert Repo.get!(Run, run.id).status == "failed"
  end

  test "only a participant's latest turn is considered", ctx do
    old = ended(ctx.dev, error: "boom")
    ended(ctx.dev, status: "completed")
    Coordinator.supervise(ctx.now)
    assert Repo.get!(Run, old.id).status == "failed"
  end

  test "a stopped turn is the human's decision and is left alone", ctx do
    run = ended(ctx.dev, status: "stopped", error: "Stopped.")
    Coordinator.supervise(ctx.now)
    assert Repo.get!(Run, run.id).status == "stopped"
  end

  test "giving up wakes the team head with what happened", ctx do
    Chat.set_team_head(ctx.lead.id)
    run = ended(ctx.dev, error: "boom", supervised_retries: Supervision.max_retries())
    Coordinator.supervise(ctx.now)

    assert Repo.get!(Run, run.id).supervised_retries == Supervision.gave_up()
    assert [notice] = notices(ctx.room)
    assert notice.body =~ "@lead dev could not finish (boom)"
    assert notice.body =~ "held back until one is retried"
    assert [%Run{status: "queued"}] = runs_for(ctx.lead)

    # Given up means given up: the next pass does nothing more.
    Coordinator.supervise(ctx.now)
    assert length(notices(ctx.room)) == 1
  end

  test "without a head, giving up is a notice that wakes nobody", ctx do
    ended(ctx.dev, error: "Authentication failed")
    Coordinator.supervise(ctx.now)
    assert [notice] = notices(ctx.room)
    assert notice.body =~ "needs attention"
    assert notice.body =~ "held back until one is retried"
    refute notice.body =~ "@"
  end

  test "the head is never woken about its own turn", ctx do
    Chat.set_team_head(ctx.lead.id)
    ended(ctx.lead, error: "Authentication failed")
    Coordinator.supervise(ctx.now)
    assert [notice] = notices(ctx.room)
    refute notice.body =~ "@"
  end

  test "wake-ups stop starting turns after six in an hour", ctx do
    Chat.set_team_head(ctx.lead.id)
    for _ <- 1..6, do: Chat.supervisor_notice(ctx.room.id, "earlier", "wake")
    ended(ctx.dev, error: "Authentication failed")
    Coordinator.supervise(ctx.now)

    last = ctx.room |> notices() |> List.last()
    assert last.body =~ "lead: dev could not finish"
    refute last.body =~ "@"
    assert runs_for(ctx.lead) == []
  end

  test "a usage limit waits for the provider's reset when quota retry is on", ctx do
    {:ok, dev} = Chat.update_agent(ctx.dev.id, %{"auto_retry" => true})
    run = ended(dev, error: "You’ve hit your usage limit. Try again at 12:47 PM.")
    Coordinator.supervise(ctx.now)

    run = Repo.get!(Run, run.id)
    assert run.status == "waiting_quota"
    assert run.retry_at
    assert [notice] = notices(ctx.room)
    assert notice.body =~ "dev hit its usage limit. Its turn resumes at"
  end

  test "a usage limit with quota retry off needs attention instead", ctx do
    run = ended(ctx.dev, error: "You’ve hit your usage limit. Try again at 12:47 PM.")
    Coordinator.supervise(ctx.now)
    assert Repo.get!(Run, run.id).status == "failed"
    assert [notice] = notices(ctx.room)
    assert notice.body =~ "automatic quota retry is off"
  end

  @tag :tmp_dir
  test "uncommitted work in a quiet room wakes the head once", %{tmp_dir: dir} = ctx do
    {_, 0} = System.cmd("git", ["init", "-q", dir])

    {_, 0} =
      System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m start),
        cd: dir
      )

    File.write!(Path.join(dir, "half_done.ex"), "")
    {:ok, room} = Chat.create_room(%{"name" => "Quiet", "directory" => dir})

    {:ok, lead} =
      Chat.create_agent(room.id, %{"name" => "lead", "provider" => "codex", "directory" => dir})

    Chat.set_team_head(lead.id)
    ended(lead, status: "completed", updated_at: DateTime.add(ctx.now, -11 * 60, :second))

    Coordinator.supervise(ctx.now)
    assert [notice] = notices(room)
    assert notice.body =~ "@lead 1 uncommitted change(s)"

    Coordinator.supervise(ctx.now)
    assert length(notices(room)) == 1
  end
end
