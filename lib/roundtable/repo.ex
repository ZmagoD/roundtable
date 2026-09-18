defmodule Roundtable.Repo do
  use Ecto.Repo,
    otp_app: :roundtable,
    adapter: Ecto.Adapters.SQLite3
end
