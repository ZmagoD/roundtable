defmodule Roundtable.LauncherTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(System.tmp_dir!(), "roundtable-launcher-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "bin"))
    launcher = Path.join(root, "bin/roundtable")
    File.cp!(Path.expand("../../bin/roundtable", __DIR__), launcher)
    on_exit(fn -> File.rm_rf!(root) end)
    %{launcher: launcher, env: [{"ROUNDTABLE_STATE_DIR", Path.join(root, "state")}]}
  end

  test "removed command reports the supported browser service commands", ctx do
    {output, status} = System.cmd("bash", [ctx.launcher, "tui"], env: ctx.env)
    assert status == 1
    assert output =~ "status [--json]"
    assert output =~ "|open|"
    refute output =~ "|tui|"
  end

  # The log also records the commands agents run, and those can name any local
  # URL. Reporting one of them sent the human to a port nothing listened on.
  test "without a URL file, status reports the port the service logged at boot", ctx do
    root = ctx.launcher |> Path.dirname() |> Path.dirname()
    state = Path.join(root, "state")
    File.mkdir_p!(state)

    File.write!(Path.join(state, "server.log"), """
    10:35:37.428 [info] Roundtable: http://127.0.0.1:4318
    13:05:23.676 [info] auto-approved for @captan: {"command":"curl http://127.0.0.1:4317/rooms/9"}
    """)

    # Stands in for the release: the launcher recognises its beam by the path.
    release = Path.join(root, "_build/prod/rel/roundtable/bin/beam")

    port =
      Port.open({:spawn_executable, "/bin/bash"}, args: ["-c", "exec -a #{release} sleep 30"])

    {:os_pid, pid} = Port.info(port, :os_pid)
    File.write!(Path.join(state, "beam.pid"), "#{pid}\n")
    on_exit(fn -> System.cmd("kill", ["#{pid}"]) end)

    {output, 0} = System.cmd("bash", [ctx.launcher, "status", "--json"], env: ctx.env)
    assert %{"running" => true, "url" => "http://127.0.0.1:4318"} = Jason.decode!(output)
  end

  test "status still works without a built or running release", ctx do
    {output, 0} = System.cmd("bash", [ctx.launcher, "status", "--json"], env: ctx.env)

    assert Jason.decode!(output) == %{
             "running" => false,
             "pid" => nil,
             "url" => nil,
             "status" => nil
           }
  end
end
