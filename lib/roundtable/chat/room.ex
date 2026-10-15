defmodule Roundtable.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :checkout_supervisor_id, :integer
    field :checkout_id, :string
    field :checkout_branch, :string
    field :checkout_finished, :boolean, default: false
    field :isolated, :boolean, virtual: true, default: false
    field :name, :string
    field :directory, :string
    # The room's shared brief: what this team is doing and how it works.
    field :context, :string, default: ""
    field :work_document, :string, default: ""
    field :work_revision, :integer, default: 0
    # A daily cap on the tokens this room's turns may spend, input plus
    # output, counted in thousands; nil means no cap of its own.
    field :token_budget, :integer
    # Each participant's turns run in a container of its own; see
    # `Roundtable.Sandbox`. The packages are Debian ones, added to the image.
    field :sandbox, :boolean, default: false
    field :sandbox_packages, :string, default: ""
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
    |> cast(attrs, [
      :isolated,
      :name,
      :directory,
      :context,
      :organization_id,
      :token_budget,
      :sandbox,
      :sandbox_packages
    ])
    |> validate_required([:name, :organization_id])
    |> validate_length(:name, max: 80)
    |> validate_length(:context, max: 4000)
    |> validate_length(:directory, max: 4096)
    |> validate_number(:token_budget, greater_than: 0, less_than: 1_000_000)
    |> packages()
  end

  # The list goes into the image's `apt-get install` line, so anything that is
  # not a Debian package name is refused rather than escaped: a name is all
  # that may reach that line.
  defp packages(changeset) do
    case get_change(changeset, :sandbox_packages) do
      nil ->
        changeset

      list ->
        names = String.split(list, ~r/[\s,]+/, trim: true)

        changeset
        |> put_change(:sandbox_packages, Enum.join(names, " "))
        |> validate_length(:sandbox_packages, max: 1000)
        |> package_names(Enum.reject(names, &Regex.match?(~r/^[a-z0-9][a-z0-9+.-]*$/, &1)))
    end
  end

  defp package_names(changeset, []), do: changeset

  defp package_names(changeset, bad),
    do: add_error(changeset, :sandbox_packages, "are not package names: #{Enum.join(bad, ", ")}")
end
