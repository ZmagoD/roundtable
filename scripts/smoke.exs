# Optional, token-consuming check against the logged-in provider CLIs.
# Use an isolated DATABASE_PATH and migrate it before running this script.
Logger.configure(level: :warning)
alias Roundtable.{Chat, Coordinator}

directory = Path.join(System.tmp_dir!(), "roundtable-smoke-workspace")
File.mkdir_p!(directory)
{:ok, room} = Chat.create_room(%{"name" => "Adapter smoke test", "directory" => directory})
Chat.subscribe(room.id)
providers = System.get_env("SMOKE_PROVIDERS", "codex,claude,opencode") |> String.split(",")
for provider <- providers do
  {:ok, _agent} = Chat.create_agent(room.id, %{"name" => provider <> "-test", "provider" => provider, "directory" => directory, "role" => "Protocol test only. Never use tools, read files, or modify anything."})
  Coordinator.post(room.id, "@#{provider}-test This is a transport test. Do not use tools or delegate. Reply with exactly: ROUNDTABLE_OK")
end

defmodule SmokeWait do
  def await(room, remaining) when remaining > 0 do
    runs = Roundtable.Chat.runs(room.id)
    if Enum.all?(runs, &(&1.status not in ["queued", "running", "approval"])) do
      runs
    else
      receive do
        :room_updated -> await(room, remaining)
      after
        1000 -> await(room, remaining - 1)
      end
    end
  end
  def await(room, 0) do
    for agent <- Roundtable.Chat.agents(room.id), do: Roundtable.Coordinator.stop(agent.id)
    Roundtable.Chat.runs(room.id)
  end
end
runs = SmokeWait.await(room, 180)
for run <- Enum.reverse(runs) do
  IO.puts("SMOKE #{run.agent.provider}: #{run.status} | session=#{run.agent.session_id != nil} | output=#{inspect(run.output)} | error=#{inspect(run.error)}")
end
successful = Enum.filter(runs, &(&1.status == "completed"))
for run <- successful do
  Coordinator.post(room.id, "@#{run.agent.name} Transport resume test. Without tools, reply with exactly the same phrase you replied with previously.")
end
if successful != [] do
  for run <- SmokeWait.await(room, 180) |> Enum.filter(&(&1.id not in Enum.map(runs, fn r -> r.id end))) do
    IO.puts("RESUME #{run.agent.provider}: #{run.status} | output=#{inspect(run.output)} | error=#{inspect(run.error)}")
  end
end
