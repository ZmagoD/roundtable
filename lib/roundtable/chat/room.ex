defmodule Roundtable.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :name, :string
    field :directory, :string
    # The room's shared brief: what this team is doing and how it works.
    field :context, :string, default: ""
    field :work_document, :string, default: ""
    field :work_revision, :integer, default: 0
    # A daily cap on the tokens this room's turns may spend, input plus
    # output, counted in thousands; nil means no cap of its own.
    field :token_budget, :integer
    belongs_to :organization, Roundtable.Chat.Organization
    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    # A cleared budget arrives from a form as an empty string, which is the
    # human saying no cap rather than a number that fails to parse.
    attrs =
      case attrs do
        %{"token_budget" => ""} -> Map.put(attrs, "token_budget", nil)
        %{token_budget: ""} -> Map.put(attrs, :token_budget, nil)
        _ -> attrs
      end

    room
    |> cast(attrs, [:name, :directory, :context, :organization_id, :token_budget])
    |> validate_required([:name, :organization_id])
    |> validate_length(:name, max: 80)
    |> validate_length(:context, max: 4000)
    |> validate_length(:directory, max: 4096)
    |> validate_number(:token_budget, greater_than: 0, less_than: 1_000_000)
  end
end
