# The pty session test boots a second VM on a real terminal; it is worth a few
# seconds in CI and not on every local run. `mix test --include pty` opts in.
ExUnit.start(exclude: [:pty])
Ecto.Adapters.SQL.Sandbox.mode(Roundtable.Repo, :manual)
