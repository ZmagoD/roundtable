import Config

if System.get_env("PHX_SERVER"), do: config(:roundtable, RoundtableWeb.Endpoint, server: true)

port = String.to_integer(System.get_env("PORT", "4317"))

if port in [3000, 4000] or port < 1024 or port > 65535 do
  raise "PORT must be between 1024 and 65535 and cannot be 3000 or 4000"
end

config :roundtable, :preferred_port, port

config :roundtable, RoundtableWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  url: [host: "localhost", port: port],
  check_origin: ["//localhost", "//127.0.0.1"]

if config_env() != :test do
  database =
    System.get_env("DATABASE_PATH") || Path.expand("../roundtable_#{config_env()}.db", __DIR__)

  config :roundtable, Roundtable.Repo,
    database: database,
    pool_size: 1,
    log: false,
    journal_mode: :wal,
    busy_timeout: 5000
end

if config_env() == :prod do
  config :roundtable, RoundtableWeb.Endpoint,
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
