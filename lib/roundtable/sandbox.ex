defmodule Roundtable.Sandbox do
  @moduledoc """
  Runs a participant's turns inside a Docker container of its own.

  Everything Docker needs is Roundtable's, not the project's: the image comes
  from `priv/sandbox/Dockerfile`, a room's extra packages are layered onto it
  here, and the container is created, recreated and removed by this module.
  Nothing is written into the room's folder.

  One long-lived container per participant, and one `docker exec` per turn.
  Whatever an agent installs survives to its next turn, and two participants
  never share a machine. The container is recreated, losing those installs,
  only when what it was made from changes: the image, the folder, the provider.

  It sees the room's folder, mounted at the same path so sessions resume, and
  its own provider's login directories so it is signed in. Nothing else of the
  human's home. It shares the host's network, which is what lets it reach the
  room tools on loopback: the sandbox protects files, not the network.
  """

  alias Roundtable.Chat

  # Where each CLI keeps its login and sessions, relative to home. Only the
  # participant's own provider is mounted, and only what exists. Claude's
  # ~/.claude.json is left out: it is rewritten by rename, which a file bind
  # mount cannot take, and the credentials live under ~/.claude anyway.
  @logins %{
    "claude" => [".claude"],
    "codex" => [".codex"],
    "opencode" => [".config/opencode", ".local/share/opencode", ".local/state/opencode"],
    "grok" => [".grok"],
    "vibe" => [".vibe"]
  }

  @home "/home/agent"

  @doc "Whether a participant's turns run in a container."
  def enabled?(%{room_id: room_id}) when is_integer(room_id), do: Chat.room!(room_id).sandbox
  def enabled?(_agent), do: false

  @doc """
  Makes sure the participant's container exists, is current and is running,
  building the image first if it has to.
  """
  def prepare(agent) do
    room = Chat.room!(agent.room_id)

    with :ok <- docker_available(),
         {:ok, image} <- image(room.sandbox_packages) do
      container(agent, image)
    end
  end

  @doc """
  The argv that runs a CLI inside the participant's container.

  `env` is what the CLI would have been started with. Its values stay in the
  docker client's environment and only the names are passed, so `docker exec`
  hands each one through without it appearing in an argument list.
  """
  def command(agent, {exe, args}, env) do
    names =
      for {name, value} <- env, value != false, name != ~c"PATH", do: to_string(name)

    {executable(),
     ["exec", "-i", "-w", agent.directory] ++
       Enum.flat_map(names, &["-e", &1]) ++ [name(agent), exe | args]}
  end

  @doc """
  Stops whatever a cancelled turn left running in the container.

  Killing the docker client does not reach the process inside. Killing the
  container does; the next turn starts it again, with its files intact.
  """
  def interrupt(agent), do: docker(["kill", name(agent)])

  @doc "Removes a participant's container, if it has one."
  def remove(agent_id) do
    if System.find_executable(executable()),
      do: docker(["rm", "-f", name(%{id: agent_id})])

    :ok
  end

  @doc "The container's name, unique to this installation's database."
  def name(%{id: id}), do: "roundtable-#{installation()}-#{id}"

  @doc "The image tag for a room's extra packages."
  def image_tag(packages \\ "") do
    base = "roundtable-agent:" <> hash(File.read!(dockerfile()))

    case packages do
      blank when blank in [nil, ""] -> base
      packages -> "roundtable-agent:" <> hash(base <> packages)
    end
  end

  @doc "The `docker run` arguments for a participant's container."
  def run_args(agent, image, home \\ System.user_home!()) do
    mounts =
      @logins
      |> Map.get(agent.provider, [])
      |> Enum.map(&Path.join(home, &1))
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(&["-v", "#{&1}:#{Path.join(@home, Path.relative_to(&1, home))}"])

    spec = hash(Enum.join([image, agent.directory, agent.provider | mounts], "\n"))

    {spec,
     [
       "run",
       "--detach",
       "--name",
       name(agent),
       "--init",
       "--network",
       "host",
       "--user",
       user(),
       "--label",
       "roundtable.spec=#{spec}",
       "--volume",
       "#{agent.directory}:#{agent.directory}"
     ] ++ mounts ++ [image, "sleep", "infinity"]}
  end

  defp container(agent, image) do
    {spec, args} = run_args(agent, image)
    name = name(agent)

    inspected =
      docker([
        "inspect",
        "--format",
        ~s({{index .Config.Labels "roundtable.spec"}} {{.State.Running}}),
        name
      ])

    case inspected do
      {:ok, found} ->
        case String.split(found) do
          [^spec, "true"] -> :ok
          [^spec, _stopped] -> started(docker(["start", name]))
          _stale -> recreate(name, args)
        end

      {:error, _absent} ->
        started(docker(args))
    end
  end

  defp recreate(name, args) do
    docker(["rm", "-f", name])
    started(docker(args))
  end

  defp started({:ok, _}), do: :ok

  defp started({:error, output}),
    do: {:error, "The sandbox did not start. Docker said: #{output}"}

  # Two turns arriving together would otherwise build the same image twice.
  # The lock is per image: a room's image takes the base image's while holding
  # its own, and one lock for both is a deadlock.
  defp image(packages) do
    tag = image_tag(packages)

    :global.trans({{__MODULE__, tag}, self()}, fn ->
      with {:error, _absent} <- docker(["image", "inspect", tag]),
           {:error, _} = failed <- build(tag, packages),
           do: failed,
           else: ({:ok, _} -> {:ok, tag})
    end)
  end

  # Built from an empty folder, so there is no build context to leak into the
  # image; the room's extras are a layer on top of the shared base.
  defp build(tag, ""), do: build_from(tag, File.read!(dockerfile()))

  defp build(tag, packages) do
    with {:ok, base} <- image("") do
      build_from(tag, """
      FROM #{base}
      USER root
      RUN apt-get update \\
       && apt-get install -y --no-install-recommends #{packages} \\
       && rm -rf /var/lib/apt/lists/*
      """)
    end
  end

  defp build_from(tag, dockerfile) do
    directory = Path.join(System.tmp_dir!(), "roundtable-image-#{hash(tag)}")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "Dockerfile"), dockerfile)

    case docker(["build", "--tag", tag, directory]) do
      {:ok, _} = built ->
        built

      {:error, output} ->
        {:error,
         "The sandbox image did not build. Check the team's extra packages. " <>
           "Docker said: " <> String.slice(output, -2000, 2000)}
    end
  after
    File.rm_rf(Path.join(System.tmp_dir!(), "roundtable-image-#{hash(tag)}"))
  end

  defp docker_available do
    case System.find_executable(executable()) && docker(["info", "--format", "{{.ID}}"]) do
      {:ok, _} ->
        :ok

      nil ->
        {:error, "This team runs its agents in containers, and Docker is not installed."}

      {:error, output} ->
        {:error,
         "This team runs its agents in containers, and Docker is not reachable: " <>
           "#{output} Start Docker, or add yourself to the docker group, then retry."}
    end
  end

  defp docker(args) do
    case System.cmd(executable(), args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp dockerfile, do: Application.app_dir(:roundtable, "priv/sandbox/Dockerfile")

  defp executable, do: Application.get_env(:roundtable, :docker, "docker")

  defp user do
    {uid, 0} = System.cmd("id", ["-u"])
    {gid, 0} = System.cmd("id", ["-g"])
    "#{String.trim(uid)}:#{String.trim(gid)}"
  end

  # Agent ids restart in every database, and a dev server and the installed
  # service share one Docker daemon.
  defp installation, do: hash(to_string(Roundtable.Repo.config()[:database]))

  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end
