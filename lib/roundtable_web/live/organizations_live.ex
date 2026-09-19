defmodule RoundtableWeb.OrganizationsLive do
  use RoundtableWeb, :live_view

  alias Roundtable.Chat

  @moduledoc """
  The projects on this machine, and the teams inside each one.

  A team is a room. This page is the layer above it: which project a room
  belongs to, where that project's work lives, and what the whole project is
  doing. Nothing here starts a turn — making a project is not a mention.
  """

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Roundtable.PubSub, "rooms")

    {:ok,
     socket
     |> assign(
       page_title: "Organizations",
       editing_id: nil,
       form_error: nil,
       organization_form: organization_form()
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:rooms_updated, socket), do: {:noreply, refresh(socket)}
  def handle_info({:room_updated, _}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("new-organization", _params, socket) do
    {:noreply,
     assign(socket, editing_id: nil, form_error: nil, organization_form: organization_form())}
  end

  def handle_event("edit-organization", %{"id" => id}, socket) do
    organization = Chat.organization!(String.to_integer(id))

    attrs = %{
      "name" => organization.name,
      "directory" => organization.directory || "",
      "context" => organization.context || ""
    }

    {:noreply,
     assign(socket,
       editing_id: organization.id,
       form_error: nil,
       organization_form: to_form(attrs, as: :organization)
     )}
  end

  def handle_event("save-organization", %{"organization" => attrs}, socket) do
    saved =
      case socket.assigns.editing_id do
        nil -> Chat.create_organization(attrs)
        id -> Chat.update_organization(id, attrs)
      end

    case saved do
      {:ok, _organization} ->
        {:noreply,
         socket
         |> assign(editing_id: nil, form_error: nil, organization_form: organization_form())
         |> refresh()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form_error: errors(changeset),
           organization_form: to_form(attrs, as: :organization)
         )}
    end
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply,
     assign(socket, editing_id: nil, form_error: nil, organization_form: organization_form())}
  end

  defp refresh(socket) do
    organizations =
      Enum.map(Chat.organizations(), fn organization ->
        %{record: organization, teams: Chat.rooms(organization.id)}
      end)

    assign(socket, organizations: organizations, rooms: Chat.rooms())
  end

  defp organization_form,
    do: to_form(%{"name" => "", "directory" => "", "context" => ""}, as: :organization)

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
