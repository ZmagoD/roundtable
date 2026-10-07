defmodule Roundtable.SpendReportTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.{Chat, Repo}
  alias Roundtable.Chat.Run

  setup do
    {:ok, room} = Chat.create_room(%{"name" => "Reported", "directory" => File.cwd!()})

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

    Chat.clear_team_head(room.id)
    %{room: room, ada: ada, linus: linus}
  end

  test "an empty room has spent nothing in either window", ctx do
    report = Chat.spend_report(ctx.room.id)
    assert report.day.by_agent == %{}
    assert report.day.by_provider == %{}
    assert report.week.by_agent == %{}
    assert report.week.by_provider == %{}
  end

  test "spend is grouped by participant and provider", ctx do
    {:ok, message} = Chat.post(ctx.room.id, "@ada have a look")
    run = Repo.one!(from r in Run, where: r.message_id == ^message.id)
    Chat.record_tokens(run, "attempt-1", %{"input" => 3_000, "output" => 500})

    report = Chat.spend_report(ctx.room.id)
    assert report.day.by_agent[ctx.ada.id] == %{"input" => 3_000, "output" => 500}
    assert report.day.by_provider == %{"codex" => %{"input" => 3_000, "output" => 500}}
    assert report.day.by_agent[ctx.linus.id] == nil
    assert report.week.by_agent[ctx.ada.id] == %{"input" => 3_000, "output" => 500}
  end

  test "a run older than a day counts in the week and not the day", ctx do
    {:ok, message} = Chat.post(ctx.room.id, "@ada old work")
    run = Repo.one!(from r in Run, where: r.message_id == ^message.id)
    Chat.record_tokens(run, "attempt-1", %{"input" => 1_000})
    two_days_ago = DateTime.add(DateTime.utc_now(:second), -2 * 24 * 3600, :second)
    Repo.update_all(Run, set: [inserted_at: two_days_ago])

    report = Chat.spend_report(ctx.room.id)
    assert report.day.by_agent == %{}
    assert report.week.by_agent[ctx.ada.id] == %{"input" => 1_000}
  end
end
