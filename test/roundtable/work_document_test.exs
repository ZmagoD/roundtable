defmodule Roundtable.WorkDocumentTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.{Chat, MCP}
  alias Roundtable.Chat.Run

  setup do
    {:ok, room} = Chat.create_room(%{name: "Focused", directory: File.cwd!()})
    {:ok, lead} = Chat.create_agent(room.id, %{name: "lead", provider: "codex"})
    {:ok, worker} = Chat.create_agent(room.id, %{name: "worker", provider: "claude"})
    {:ok, lead} = Chat.set_team_head(lead.id)
    %{room: room, lead: lead, worker: worker}
  end

  test "human messages default to the head without changing their body", ctx do
    {:ok, message} = Chat.post(ctx.room.id, "Please fix the form")
    assert message.body == "Please fix the form"
    assert [%{agent_id: id}] = Chat.runs(ctx.room.id)
    assert id == ctx.lead.id
  end

  test "explicit mentions override the default and unknown mentions do not fall back", ctx do
    {:ok, _} = Chat.post(ctx.room.id, "@worker check it")
    assert [%{agent_id: id}] = Chat.runs(ctx.room.id)
    assert id == ctx.worker.id

    for body <- ["@missing check it", "@elsewhere/person check it"] do
      Chat.post(ctx.room.id, body)
    end

    assert length(Chat.runs(ctx.room.id)) == 1
  end

  test "system messages and unaddressed agent replies never wake the head", ctx do
    Chat.post(ctx.room.id, "Done", kind: "agent", agent_id: ctx.worker.id)
    Chat.post(ctx.room.id, "Updated", kind: "system")
    assert Chat.runs(ctx.room.id) == []
    Chat.clear_team_head(ctx.room.id)
    Chat.post(ctx.room.id, "Just a note")
    assert Chat.runs(ctx.room.id) == []
  end

  test "document edits reject stale revisions and oversized bodies", ctx do
    assert {:ok, room} = Chat.update_work_document(ctx.room.id, "T1 | worker | ready", 0)
    assert room.work_revision == 1
    assert {:error, _} = Chat.update_work_document(ctx.room.id, "stale", 0)
    assert {:error, _} = Chat.update_work_document(ctx.room.id, String.duplicate("x", 8001), 1)
    assert Chat.work_document(ctx.room.id) == %{body: "T1 | worker | ready", revision: 1}
    assert {:ok, _} = Chat.update_work_document(ctx.room.id, "", 1)
  end

  test "focused prompts carry the document and assignment without unrelated chat", ctx do
    Chat.update_work_document(ctx.room.id, "T1 | worker | fix expiry", 0)
    Chat.post(ctx.room.id, "Unrelated long conversation", kind: "agent")
    {:ok, message} = Chat.post(ctx.room.id, "@worker Implement T1")
    run = Repo.one!(from r in Run, where: r.message_id == ^message.id)
    {prompt, until_id} = Chat.prompt(ctx.worker, run)
    assert prompt =~ "T1 | worker | fix expiry"
    assert prompt =~ "Implement T1"
    assert prompt =~ "Return a short result to @lead"
    refute prompt =~ "Unrelated long conversation"
    assert until_id == message.id
  end

  test "tools scope history and documents to the calling room and enforce the head", ctx do
    assert {:error, _} =
             MCP.call(ctx.worker, "update_work_document", %{"body" => "oops", "revision" => 0})

    assert {:ok, _} =
             MCP.call(ctx.lead, "update_work_document", %{"body" => "T1 ready", "revision" => 0})

    assert {:error, _} =
             MCP.call(ctx.lead, "update_work_document", %{"body" => "stale", "revision" => 0})

    assert {:ok, text} = MCP.call(ctx.worker, "read_work_document")
    assert Jason.decode!(text)["body"] == "T1 ready"
    {:ok, other} = Chat.create_room(%{name: "Other", directory: File.cwd!()})
    Chat.post(other.id, "Other room secret")
    for n <- 1..12, do: Chat.post(ctx.room.id, "Message #{n}", kind: "system")
    {:ok, large} = Chat.post(ctx.room.id, String.duplicate("x", 3000), kind: "system")
    assert {:ok, text} = MCP.call(ctx.worker, "read_room_history", %{"before_id" => large.id + 1})
    messages = Jason.decode!(text)
    assert length(messages) == 10
    assert List.last(messages)["truncated"]
    assert String.length(List.last(messages)["body"]) == 2000
    refute text =~ "Other room secret"

    assert {:ok, previous} =
             MCP.call(ctx.worker, "read_room_history", %{"before_id" => hd(messages)["id"]})

    assert length(Jason.decode!(previous)) == 3
    assert {:error, _} = MCP.call(ctx.worker, "read_room_history", %{"before_id" => -1})
  end
end
