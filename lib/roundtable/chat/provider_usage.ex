defmodule Roundtable.Chat.ProviderUsage do
  use Ecto.Schema

  @primary_key {:provider, :string, autogenerate: false}
  schema "provider_usage" do
    field :data, :map, default: %{}
    field :recorded_at, :utc_datetime_usec
  end
end
