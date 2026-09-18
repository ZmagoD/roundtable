defmodule Roundtable.Agents.ProtocolTest do
  @moduledoc """
  Contract tests for the provider adapters.

  Provider protocols change under us, and a wrong clause here does not crash —
  it silently drops a turn's output, misses a session id, or leaves a turn that
  never finishes. These pin the shapes each adapter promises to understand.
  """
  use ExUnit.Case, async: true

  alias Roundtable.Agents
  alias Roundtable.Agents.{Claude, Codex, Grok, OpenCode, Protocol}

  # `cat` echoes whatever the adapter writes back to this process, so the bytes
  # on the wire can be asserted rather than assumed.
  defp state(overrides \\ %{}) do
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])

    Map.merge(
      %{
        run: %{id: -1},
        agent: %{directory: "/tmp", model: nil, session_id: nil},
        prompt: "do the thing",
        port: port,
        output: "",
        diagnostics: "",
        items: %{},
        item_order: [],
        final_output: nil,
        pending: %{},
        finished: false,
        session: nil,
        flush: nil
      },
      overrides
    )
  end

  # Adapters write through the bridge envelope, and `cat` may hand several
  # writes over in one chunk, so unwrap and queue whatever arrives.
  defp written(state) do
    key = {:written, state.port}

    case Process.get(key, []) do
      [next | rest] ->
        Process.put(key, rest)
        next

      [] ->
        port = state.port
        assert_receive {^port, {:data, data}}, 1000

        [next | rest] =
          data
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            line |> Jason.decode!() |> Map.fetch!("write") |> Jason.decode!()
          end)

        Process.put(key, rest)
        next
    end
  end

  # put_output/2 schedules a flush; cancel it so it cannot outlive the test.
  defp settle(state) do
    if state.flush, do: Process.cancel_timer(state.flush)
    state
  end

  describe "command building" do
    test "claude streams both ways and routes approvals over stdio" do
      {exe, args} = Protocol.command(%{provider: "claude", session_id: nil, model: nil})

      assert exe == "claude"
      assert "--output-format" in args and "stream-json" in args
      assert "--input-format" in args
      assert "--permission-prompt-tool" in args
      refute "--resume" in args
      refute "--model" in args
    end

    test "a session or a model is passed only when there is one" do
      {_, args} = Protocol.command(%{provider: "claude", session_id: "abc", model: "opus"})
      pairs = Enum.chunk_every(args, 2, 1)

      assert ["--resume", "abc"] in pairs
      assert ["--model", "opus"] in pairs

      # Empty is the same as absent: an empty flag value would be a parse error.
      {_, args} = Protocol.command(%{provider: "opencode", session_id: "", model: ""})
      assert args == ["run", "--format", "json"]
    end

    test "each provider has its own transport" do
      assert {"codex", ["app-server"]} =
               Protocol.command(%{provider: "codex", session_id: nil, model: nil})

      assert {"opencode", ["run", "--format", "json" | _]} =
               Protocol.command(%{provider: "opencode", session_id: nil, model: nil})
    end

    test "text blocks ignore everything that is not text" do
      blocks = [
        %{"type" => "text", "text" => "one"},
        %{"type" => "tool_use", "name" => "bash"},
        %{"type" => "text", "text" => "two"}
      ]

      assert Protocol.text_blocks(blocks) == "one\ntwo"
      assert Protocol.text_blocks(nil) == ""
      assert Protocol.text_blocks("not a list") == ""
    end
  end

  describe "claude" do
    test "remembers the session id it is given" do
      state = Claude.handle_event(%{"type" => "system", "session_id" => "sess-1"}, state())
      assert state.session == "sess-1"
    end

    test "streams partial text into the output" do
      delta = fn text ->
        %{
          "type" => "stream_event",
          "event" => %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => text}
          }
        }
      end

      state = state() |> then(&Claude.handle_event(delta.("Hel"), &1)) |> settle()
      state = state |> then(&Claude.handle_event(delta.("lo"), &1)) |> settle()

      assert state.output == "Hello"
    end

    test "a whole assistant message is a fallback, not an overwrite" do
      message = %{"content" => [%{"type" => "text", "text" => "whole"}]}
      event = %{"type" => "assistant", "message" => message}

      assert %{output: "whole"} = event |> Claude.handle_event(state()) |> settle()

      # Partial events already produced text, so the fallback must not clobber it.
      assert %{output: "streamed"} =
               event |> Claude.handle_event(state(%{output: "streamed"})) |> settle()
    end

    test "a result ends the turn, and reports an error when it is one" do
      assert %{finished: {"completed", nil}} =
               %{"type" => "result", "result" => "done"}
               |> Claude.handle_event(state())
               |> settle()

      assert %{finished: {"failed", "boom"}} =
               %{"type" => "result", "is_error" => true, "errors" => ["boom"]}
               |> Claude.handle_event(state())
               |> settle()
    end

    test "a tool request becomes a pending approval" do
      request = %{"subtype" => "can_use_tool", "input" => %{"command" => "ls"}}

      state =
        Claude.handle_event(
          %{"type" => "control_request", "request_id" => "r1", "request" => request},
          state()
        )

      assert Map.has_key?(state.pending, "r1")
    end

    test "accepting returns the tool's input; declining says a human declined" do
      state = state()

      Claude.approve(state, "r1", "accept", %{"input" => %{"command" => "ls"}})
      assert %{"response" => %{"response" => response}} = written(state)
      assert response["behavior"] == "allow"
      assert response["updatedInput"] == %{"command" => "ls"}

      Claude.approve(state, "r1", "decline", %{})
      assert %{"response" => %{"response" => %{"behavior" => "deny"}}} = written(state)
    end

    test "an unsupported control request is answered, not ignored" do
      state = state()
      Claude.handle_event(%{"type" => "control_request", "request_id" => "r9"}, state)
      assert %{"response" => %{"subtype" => "error"}} = written(state)
    end

    test "an unknown event changes nothing" do
      state = state()
      assert Claude.handle_event(%{"type" => "something new"}, state) == state
    end
  end

  describe "grok" do
    test "runs headless in the Messages wire format" do
      {exe, args} = Grok.command(%{session_id: nil, model: nil}, "do the thing")

      assert exe == "grok"
      # The CLI documents no way to read the prompt from stdin.
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-p", "do the thing"])

      assert Enum.chunk_every(args, 2, 1)
             |> Enum.member?(["--output-format", "streaming-messages-json"])

      assert "--include-partial-messages" in args
      refute "--resume" in args
      refute "--model" in args
    end

    test "resumes a session and pins a model when there is one" do
      {_, args} = Grok.command(%{session_id: "s-1", model: "grok-4.6"}, "go")
      pairs = Enum.chunk_every(args, 2, 1)

      assert ["--resume", "s-1"] in pairs
      assert ["--model", "grok-4.6"] in pairs
    end

    test "it reads the same events Claude Code emits" do
      state = state()

      assert %{session: "s-9"} =
               Grok.handle_event(%{"type" => "system", "session_id" => "s-9"}, state)

      assert %{output: "streamed"} =
               %{
                 "type" => "stream_event",
                 "event" => %{
                   "type" => "content_block_delta",
                   "delta" => %{"type" => "text_delta", "text" => "streamed"}
                 }
               }
               |> Grok.handle_event(state)
               |> settle()

      assert %{finished: {"completed", nil}} =
               %{"type" => "result", "result" => "done"}
               |> Grok.handle_event(state)
               |> settle()
    end

    test "an unauthenticated run fails with what the CLI said" do
      # Captured from a real `grok -p ... --output-format streaming-messages-json`.
      event = %{
        "type" => "result",
        "subtype" => "error_during_execution",
        "is_error" => true,
        "errors" => ["Not signed in. To authenticate without a browser, run:\n  grok login"],
        "session_id" => ""
      }

      assert %{finished: {"failed", message}} = event |> Grok.handle_event(state()) |> settle()
      assert message =~ "Not signed in"
    end

    test "an empty session id is not a session" do
      # The CLI sends session_id: "" before it has one.
      assert %{session: nil} =
               Grok.handle_event(%{"type" => "system", "session_id" => ""}, state())
    end

    test "it cannot grant an approval" do
      assert Grok.approve(state(), "r1", "accept", %{}) == :unsupported
    end

    test "a clean exit counts only when something was said" do
      assert Grok.exit_status(0, %{output: "answer", diagnostics: ""}) == {"completed", nil}
      assert {"failed", _} = Grok.exit_status(0, %{output: "", diagnostics: "why"})
      assert {"failed", _} = Grok.exit_status(2, %{output: "answer", diagnostics: "why"})
    end
  end

  describe "model listings" do
    test "one name per line, with prose rejected" do
      assert Agents.parse_lines("openrouter/mistralai/mistral-large\nopencode/big-pickle\n") ==
               ["openrouter/mistralai/mistral-large", "opencode/big-pickle"]

      # An unauthenticated CLI explains itself; that is not a model.
      assert Agents.parse_lines("You are not authenticated.\n\ngrok-4.6\n") == ["grok-4.6"]
    end

    test "bullets, as Grok prints them" do
      # Captured from a real `grok models`.
      output = """
      You are not authenticated.

      Default model: grok-4.6

      Available models:
        * grok-4.6 (default)
        - grok-4.5
      """

      assert Agents.parse_bullets(output) == ["grok-4.6", "grok-4.5"]
    end

    test "a provider that cannot list gets nothing rather than a guess" do
      assert Agents.models("codex") == []
      assert Agents.models("nothing-like-this") == []
    end
  end

  describe "opencode" do
    test "accumulates text and tracks the session" do
      event = %{"sessionID" => "s1", "type" => "text", "part" => %{"text" => "hello"}}
      state = event |> OpenCode.handle_event(state()) |> settle()

      assert state.session == "s1"
      assert state.output == "hello\n"
    end

    test "an error ends the turn, with or without a session" do
      assert %{finished: {"failed", _}} =
               OpenCode.handle_event(
                 %{"sessionID" => "s1", "type" => "error", "error" => "nope"},
                 state()
               )

      assert %{finished: {"failed", _}} =
               OpenCode.handle_event(%{"type" => "error", "error" => "nope"}, state())
    end

    test "a clean exit counts only when something was said" do
      assert OpenCode.exit_status(0, %{output: "answer", diagnostics: ""}) == {"completed", nil}
      assert {"failed", _} = OpenCode.exit_status(0, %{output: "", diagnostics: "why"})
      assert {"failed", _} = OpenCode.exit_status(1, %{output: "answer", diagnostics: "why"})
    end

    test "it cannot grant an approval" do
      assert OpenCode.approve(state(), "r1", "accept", %{}) == :unsupported
    end
  end

  describe "codex" do
    test "a protocol error ends the turn with the provider's message" do
      assert %{finished: {"failed", "bad request"}} =
               Codex.handle_event(%{"id" => 3, "error" => %{"message" => "bad request"}}, state())
    end

    test "a turn that does not complete is a failure with its reason" do
      assert %{finished: {"failed", "ran out"}} =
               %{
                 "method" => "turn/completed",
                 "params" => %{
                   "turn" => %{"status" => "failed", "error" => %{"message" => "ran out"}}
                 }
               }
               |> Codex.handle_event(state())
               |> settle()
    end

    test "an approval request is held for the human" do
      state =
        Codex.handle_event(
          %{
            "id" => 7,
            "method" => "item/commandExecution/requestApproval",
            "params" => %{"command" => "rm -rf /"}
          },
          state()
        )

      assert Map.has_key?(state.pending, 7)
    end

    test "a method it does not support is declined by number, not ignored" do
      state = state()
      Codex.handle_event(%{"id" => 4, "method" => "fs/readTextFile"}, state)

      assert %{"error" => %{"code" => -32_601, "message" => message}} = written(state)
      assert message =~ "fs/readTextFile"
    end

    test "the thread is resumed when there is a session, and started when not" do
      fresh = state()
      Codex.handle_event(%{"id" => 1, "result" => %{}}, fresh)
      assert %{"method" => "initialized"} = written(fresh)
      assert %{"method" => "thread/start", "params" => params} = written(fresh)
      assert params["cwd"] == "/tmp"
      assert params["sandbox"] == "workspace-write"
      refute Map.has_key?(params, "model")

      resuming = state(%{session: "t-1"})
      Codex.handle_event(%{"id" => 1, "result" => %{}}, resuming)
      assert %{"method" => "initialized"} = written(resuming)

      assert %{"method" => "thread/resume", "params" => %{"threadId" => "t-1"}} =
               written(resuming)
    end

    test "a model is sent only when the assignment has one" do
      state = state(%{agent: %{directory: "/tmp", model: "o3", session_id: nil}})
      Codex.handle_event(%{"id" => 1, "result" => %{}}, state)

      written(state)
      assert %{"params" => %{"model" => "o3"}} = written(state)
    end
  end
end
