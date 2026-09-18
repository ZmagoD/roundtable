import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# DATABASE_PATH is honoured here too, so a test can start a second instance of
# the app in its own database instead of writing into the suite's, outside the
# sandbox, where no rollback can reach it.
config :roundtable, Roundtable.Repo,
  database: System.get_env("DATABASE_PATH") || Path.expand("../roundtable_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :roundtable, RoundtableWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Xh136MF3GCemWRddKul/AIEW0j7o/Fi55esU3TtbzfXD0XA9QeNMsTychp+movrc",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :roundtable, :start_agents, false
