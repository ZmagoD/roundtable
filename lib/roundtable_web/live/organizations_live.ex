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
       inheriting: [],
       custom: [],
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

    {inheriting, custom} =
      organization.id |> Chat.rooms() |> Enum.split_with(&(&1.directory in [nil, ""]))

    {:noreply,
     assign(socket,
       editing_id: organization.id,
       form_error: nil,
       inheriting: inheriting,
       custom: custom,
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
      # A new project opens on its own, still empty: the next thing to do there
      # is make its first team, and nothing has started running.
      {:ok, organization} when is_nil(socket.assigns.editing_id) ->
        {:noreply, push_navigate(socket, to: ~p"/?organization=#{organization.id}")}

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
    status = Map.new(Chat.overview().rooms, &{&1.id, &1})

    organizations =
      Enum.map(Chat.organizations(), fn organization ->
        teams =
          organization.id
          |> Chat.rooms()
          |> Enum.map(&team(&1, Map.get(status, &1.id, %{})))

        %{record: organization, teams: teams}
      end)

    assign(socket, organizations: organizations, rooms: Chat.rooms())
  end

  # The one thing to act on first, in words, so the state never rests on colour
  # alone: someone waiting on you outranks someone working.
  defp team(room, counts) do
    head = Chat.team_head(room.id)
    approval = Map.get(counts, :waiting_for_approval, 0)
    running = Map.get(counts, :running, 0)
    queued = Map.get(counts, :queued, 0) + Map.get(counts, :waiting_for_quota, 0)

    {state, label} =
      cond do
        approval > 0 -> {"approval", "#{approval} needs approval"}
        running > 0 -> {"working", "#{running} working"}
        queued > 0 -> {"queued", "#{queued} queued"}
        true -> {"idle", "Idle"}
      end

    %{
      room: room,
      head: head && head.name,
      members: Map.get(counts, :participants, 0),
      state: state,
      status: label
    }
  end

  def team_summary(team) do
    head = if team.head, do: "Head: #{team.head}", else: "No team head"
    "#{head} · #{team.members} #{if team.members == 1, do: "member", else: "members"}"
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
