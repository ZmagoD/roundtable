defmodule Roundtable.SandboxTest do
  use Roundtable.DataCase, async: false

  alias Roundtable.{Agents, Chat, Coordinator, Sandbox}

  defp tmp(name) do
    directory = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  describe "a room's extra packages" do
    test "are package names, and nothing else reaches the image" do
      {:ok, room} =
        Chat.create_room(%{
          name: "Sandboxed",
          directory: File.cwd!(),
          sandbox: true,
          sandbox_packages: " elixir,  build-essential\nlibssl3 "
        })

      assert room.sandbox
      assert room.sandbox_packages == "elixir build-essential libssl3"

      for bad <- ["curl; rm -rf /", "Elixir", "$(id)", "-y"] do
        assert {:error, changeset} = Chat.update_room(room.id, %{sandbox_packages: bad})
        assert errors_on(changeset).sandbox_packages != []
      end
    end

    test "give a room an image of its own on top of the shared one" do
      assert Sandbox.image_tag("") == Sandbox.image_tag()
      refute Sandbox.image_tag("elixir") == Sandbox.image_tag()
      refute Sandbox.image_tag("elixir") == Sandbox.image_tag("python3")
    end
  end

  describe "the container" do
    test "sees the project at its own path and only its provider's login" do
      home = tmp("roundtable-home")
      for dir <- [".codex", ".claude"], do: File.mkdir_p!(Path.join(home, dir))
      agent = %{id: 7, provider: "codex", directory: "/work/project"}

      {spec, args} = Sandbox.run_args(agent, "roundtable-agent:abc", home)
      pairs = Enum.chunk_every(args, 2, 1)

      assert ["--volume", "/work/project:/work/project"] in pairs
      assert ["-v", "#{home}/.codex:/home/agent/.codex"] in pairs
      refute Enum.any?(args, &String.contains?(&1, ".claude"))
      assert ["--network", "host"] in pairs
      assert ["--name", Sandbox.name(agent)] in pairs
      assert ["--label", "roundtable.spec=#{spec}"] in pairs
      assert Enum.take(args, -3) == ["roundtable-agent:abc", "sleep", "infinity"]

      # Anything it was made from changing means a new container.
      {other, _} = Sandbox.run_args(%{agent | provider: "claude"}, "roundtable-agent:abc", home)
      refute other == spec
    end

    test "a turn hands environment through by name, never by value" do
      agent = %{id: 7, directory: "/work/project"}

      env = [
        {~c"RELEASE_COOKIE", false},
        {~c"PATH", ~c"/usr/bin"},
        {~c"ROUNDTABLE_MCP_TOKEN", ~c"secret"}
      ]

      {exe, args} = Sandbox.command(agent, {"claude", ["-p"]}, env)

      assert exe == "roundtable-test-no-docker"

      assert args ==
               ["exec", "-i", "-w", "/work/project", "-e", "ROUNDTABLE_MCP_TOKEN"] ++
                 [Sandbox.name(agent), "claude", "-p"]

      refute Enum.any?(args, &String.contains?(&1, "secret"))
    end

    test "names are this installation's own" do
      refute Sandbox.name(%{id: 1}) == "roundtable-1"
      assert Sandbox.name(%{id: 1}) =~ ~r/^roundtable-[0-9a-f]{12}-1$/
    end
  end

  # A stand-in for the docker CLI: it records each call, answers from
  # `answers` (keyed by the first two arguments, or the first) and runs
  # `exec`'s command right here instead of in a container. Unless told
  # otherwise there is no container yet and everything else succeeds.
  defp fake_docker(answers \\ %{}) do
    directory = tmp("roundtable-docker")
    log = Path.join(directory, "calls")
    docker = Path.join(directory, "docker")
    answers_file = Path.join(directory, "answers.json")

    File.write!(
      answers_file,
      Jason.encode!(Map.merge(%{"inspect" => [1, "No such object"]}, answers))
    )

    File.write!(docker, """
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    with open(#{inspect(log)}, "a") as log:
        log.write(" ".join(args) + "\\n")
    if args[0] == "exec":
        rest = args[1:]
        while rest[0] in ("-i", "-w", "-e"):
            rest = rest[1:] if rest[0] == "-i" else rest[2:]
        os.execvp(rest[1], rest[1:])
    answers = json.load(open(#{inspect(answers_file)}))
    code, output = answers.get(" ".join(args[:2]), answers.get(args[0], [0, "ok"]))
    print(output)
    sys.exit(code)
    """)

    File.chmod!(docker, 0o755)
    Application.put_env(:roundtable, :docker, docker)
    on_exit(fn -> Application.put_env(:roundtable, :docker, "roundtable-test-no-docker") end)
    log
  end

  defp calls(log), do: log |> File.read!() |> String.split("\n", trim: true)

  defp with_fixture_agents do
    original = Agents.adapters()
    Application.put_env(:roundtable, :adapters, original ++ [Roundtable.FixtureAdapter])
    Application.put_env(:roundtable, :start_agents, true)

    on_exit(fn ->
      Application.put_env(:roundtable, :start_agents, false)
      Application.put_env(:roundtable, :adapters, original)
    end)
  end

  defp boxed(attrs \\ %{}, provider \\ "codex") do
    {:ok, room} =
      Chat.create_room(Map.merge(%{name: "Boxed", directory: File.cwd!(), sandbox: true}, attrs))

    {:ok, agent} = Chat.create_agent(room.id, %{"name" => "boxed", "provider" => provider})
    {room, agent}
  end

  defp spec(agent, image \\ Sandbox.image_tag()),
    do: agent |> Sandbox.run_args(image) |> elem(0)

  describe "a turn" do
    test "runs through the participant's container" do
      log = fake_docker()
      with_fixture_agents()
      {room, agent} = boxed(%{}, "fixture")

      Chat.subscribe(room.id)
      Coordinator.post(room.id, "@boxed hello")
      wait_for(fn -> map_size(Coordinator.approvals()) == 1 end)
      [approval] = Map.values(Coordinator.approvals())
      Coordinator.approve(approval.run_id, "fixture-request", "decline")
      wait_for(fn -> match?([%{status: "completed"}], Chat.runs(room.id)) end)

      calls = File.read!(log)
      name = Sandbox.name(agent)
      assert calls =~ "image inspect #{Sandbox.image_tag()}"
      assert calls =~ ~r/^run --detach --name #{name} /m
      assert calls =~ ~r/^exec -i -w #{Regex.escape(File.cwd!())} .*#{name} python3 /m
      # It finished on its own, so the container is left running for next time.
      refute calls =~ "kill"
    end

    test "that is stopped stops what is running in its container" do
      log = fake_docker()
      with_fixture_agents()
      {room, agent} = boxed(%{}, "fixture")

      Chat.subscribe(room.id)
      Coordinator.post(room.id, "@boxed hello")
      wait_for(fn -> map_size(Coordinator.approvals()) == 1 end)
      Coordinator.stop(agent.id)
      wait_for(fn -> File.read!(log) =~ "kill #{Sandbox.name(agent)}" end)
    end

    test "that cannot prepare its container fails with the reason, and runs nothing" do
      log = fake_docker(%{"info" => [1, "permission denied while trying to connect"]})
      with_fixture_agents()
      {room, _agent} = boxed(%{}, "fixture")

      Chat.subscribe(room.id)
      Coordinator.post(room.id, "@boxed hello")
      wait_for(fn -> match?([%{status: "failed"}], Chat.runs(room.id)) end)

      assert [%{error: error}] = Chat.runs(room.id)
      assert error =~ "Docker is not reachable"
      assert error =~ "permission denied"
      assert error =~ "docker group"
      refute File.read!(log) =~ "exec"
    end

    test "in a room that is not sandboxed never touches docker" do
      log = fake_docker()
      with_fixture_agents()
      {room, _agent} = boxed(%{sandbox: false}, "fixture")

      Chat.subscribe(room.id)
      Coordinator.post(room.id, "@boxed hello")
      wait_for(fn -> map_size(Coordinator.approvals()) == 1 end)
      [approval] = Map.values(Coordinator.approvals())
      Coordinator.approve(approval.run_id, "fixture-request", "decline")
      wait_for(fn -> match?([%{status: "completed"}], Chat.runs(room.id)) end)

      refute File.exists?(log)
    end
  end

  describe "preparing a container" do
    test "leaves a current, running one alone" do
      {_room, agent} = boxed()
      log = fake_docker(%{"inspect" => [0, "#{spec(agent)} true"]})

      assert Sandbox.prepare(agent) == :ok
      refute Enum.any?(calls(log), &String.starts_with?(&1, ["run", "start", "rm"]))
    end

    test "starts a current one that was stopped, keeping its files" do
      {_room, agent} = boxed()
      log = fake_docker(%{"inspect" => [0, "#{spec(agent)} false"]})

      assert Sandbox.prepare(agent) == :ok
      assert "start #{Sandbox.name(agent)}" in calls(log)
      refute Enum.any?(calls(log), &String.starts_with?(&1, ["run", "rm"]))
    end

    test "replaces one made from something that has since changed" do
      {_room, agent} = boxed()
      log = fake_docker(%{"inspect" => [0, "an-older-spec true"]})

      assert Sandbox.prepare(agent) == :ok
      calls = calls(log)
      remove = Enum.find_index(calls, &(&1 == "rm -f #{Sandbox.name(agent)}"))
      run = Enum.find_index(calls, &String.starts_with?(&1, "run "))
      assert remove && run && remove < run
    end

    test "says why a container did not start" do
      {_room, agent} = boxed()
      fake_docker(%{"run" => [1, "port is already allocated"]})

      assert {:error, message} = Sandbox.prepare(agent)
      assert message =~ "The sandbox did not start"
      assert message =~ "port is already allocated"
    end

    test "builds the shared image first, then the room's packages on top of it" do
      {_room, agent} = boxed(%{sandbox_packages: "elixir erlang"})
      log = fake_docker(%{"image inspect" => [1, "No such image"]})

      assert Sandbox.prepare(agent) == :ok
      base = Sandbox.image_tag()
      room_image = Sandbox.image_tag("elixir erlang")
      builds = Enum.filter(calls(log), &String.starts_with?(&1, "build "))

      assert [
               "build --tag " <> ^base <> _,
               "build --tag " <> ^room_image <> _
             ] = builds

      assert Enum.any?(calls(log), &(&1 =~ ~r/^run .* #{room_image} sleep infinity$/))
    end

    test "says a failed build is about the team's packages, with what docker said" do
      {_room, agent} = boxed(%{sandbox_packages: "no-such-package"})

      log =
        fake_docker(%{
          "image inspect" => [1, "No such image"],
          "build" => [1, "E: Unable to locate package no-such-package"]
        })

      assert {:error, message} = Sandbox.prepare(agent)
      assert message =~ "extra packages"
      assert message =~ "Unable to locate package no-such-package"
      refute Enum.any?(calls(log), &String.starts_with?(&1, "run "))
    end

    test "says so when Docker is missing" do
      {_room, agent} = boxed()

      assert {:error, message} = Sandbox.prepare(agent)
      assert message =~ "Docker is not installed"
    end
  end

  describe "removing" do
    test "a participant removes its container" do
      log = fake_docker()
      {_room, agent} = boxed()

      assert {:ok, _} = Coordinator.remove_agent(agent.id)

      wait_until(fn ->
        File.exists?(log) and File.read!(log) =~ "rm -f #{Sandbox.name(agent)}"
      end)
    end

    test "a room removes every participant's container, sandboxed or not any more" do
      log = fake_docker()
      {room, first} = boxed(%{sandbox: false})
      {:ok, second} = Chat.create_agent(room.id, %{"name" => "other", "provider" => "codex"})

      Coordinator.remove_room(room.id)

      wait_until(fn ->
        File.exists?(log) and
          Enum.all?([first, second], &(File.read!(log) =~ "rm -f #{Sandbox.name(&1)}"))
      end)
    end

    test "is nothing without docker" do
      assert Sandbox.remove(123) == :ok
    end
  end

  # Container removal runs beside the queue, not in it, so nothing announces it.
  defp wait_until(condition, tries \\ 60) do
    cond do
      condition.() -> :ok
      tries == 0 -> flunk("Timed out waiting for docker to be called")
      true -> Process.sleep(50) && wait_until(condition, tries - 1)
    end
  end

  defp wait_for(condition) do
    if not condition.() do
      receive do
        :room_updated -> wait_for(condition)
      after
        3000 -> flunk("Timed out waiting for the sandboxed turn")
      end
    end
  end
end
