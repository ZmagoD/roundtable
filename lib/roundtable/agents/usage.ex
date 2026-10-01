defmodule Roundtable.Agents.Usage do
  @moduledoc false
  alias Roundtable.{Coordinator, Usage}

  def report(state, tokens) when map_size(tokens) == 0, do: state

  def report(state, tokens) do
    state = Map.put_new_lazy(state, :usage_attempt, &Ecto.UUID.generate/0)
    tokens = Map.merge(Map.get(state, :usage_tokens, %{}), tokens)
    Coordinator.event(state.run.id, {:tokens, state.usage_attempt, tokens})
    Map.put(state, :usage_tokens, tokens)
  end

  def claude_message(state, %{"id" => id, "usage" => usage}) do
    tokens = Usage.claude_tokens(usage)
    messages = Map.get(state, :usage_messages, %{})
    messages = Map.update(messages, id, tokens, &Map.merge(&1, tokens))
    state |> Map.put(:usage_messages, messages) |> report(Usage.sum(Map.values(messages)))
  end

  def claude_message(state, _), do: state

  def opencode_step(state, %{"id" => id, "tokens" => tokens}) when is_map(tokens) do
    counts = Usage.tokens(tokens, [{"input", "input"}, {"output", "output"}])
    cache = Usage.tokens(tokens["cache"], [{"cached", "read"}, {"cache_write", "write"}])
    steps = Map.get(state, :usage_steps, %{})

    steps =
      Map.update(steps, id, Map.merge(counts, cache), &Map.merge(&1, Map.merge(counts, cache)))

    state |> Map.put(:usage_steps, steps) |> report(Usage.sum(Map.values(steps)))
  end

  def opencode_step(state, _), do: state

  def codex(state, %{"turnId" => turn_id, "tokenUsage" => usage}) do
    if Map.get(state, :usage_turn_id) == turn_id do
      codex_update(state, usage)
    else
      state
    end
  end

  def codex(state, _), do: state

  defp codex_update(state, usage) do
    total = Usage.codex_tokens(usage["total"])
    last = Usage.codex_tokens(usage["last"])
    previous = Map.get(state, :usage_codex_total, %{})

    # `last` is one model response, not the entire turn. The thread total may
    # include earlier resumed turns; only differences after the first report
    # belong to this attempt. Replayed snapshots consequently add nothing.
    delta =
      Map.new(
        for {key, value} <- total do
          count =
            case previous do
              %{^key => old} when value >= old -> value - old
              _ -> Map.get(last, key)
            end

          {key, count}
        end
      )
      |> Usage.valid_tokens()

    tokens = Usage.sum([Map.get(state, :usage_tokens, %{}), delta])
    state |> Map.put(:usage_codex_total, Map.merge(previous, total)) |> report(tokens)
  end
end
