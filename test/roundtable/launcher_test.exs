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
