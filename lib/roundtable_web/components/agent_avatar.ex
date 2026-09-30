defmodule RoundtableWeb.AgentAvatar do
  @moduledoc """
  A participant's picture, drawn from its name and role.

  Computed rather than fetched: the same name always gives the same picture,
  offline and without an image service. The pattern says who, the corner mark
  says what for, and the frame keeps the provider's colour it always had.
  """
  use Phoenix.Component
  import Bitwise
  import RoundtableWeb.CoreComponents, only: [icon: 1]

  @size 5
  @hues 6

  # A brief names who someone works with as well as what they are — "Developer
  # … working for @captan", "Tests ship with the change" — so the keyword that
  # comes first in the role wins, not the first entry in this list.
  @marks [
    {~w(captain captan lead head orchestrat), "hero-star-mini"},
    {~w(product planner planning), "hero-clipboard-document-list-mini"},
    {~w(qa tester testing review verif), "hero-check-badge-mini"},
    {~w(develop engineer implement programmer), "hero-code-bracket-mini"}
  ]

  attr :name, :string, required: true
  attr :role, :string, default: nil
  attr :provider, :string, default: nil
  attr :class, :any, default: nil

  def agent_avatar(assigns) do
    assigns =
      assign(assigns,
        cells: cells(assigns.name),
        hue: hue(assigns.name),
        mark: mark(assigns.role)
      )

    ~H"""
    <div
      class={["avatar", "agent-avatar", @provider, @class]}
      role="img"
      aria-label={@name}
      title={@name}
    >
      <svg class={["avatar-pattern", "avatar-hue-#{@hue}"]} viewBox="0 0 5 5" aria-hidden="true">
        <rect :for={{x, y} <- @cells} x={x} y={y} width="1" height="1" />
      </svg>
      <span :if={@mark} class="avatar-mark"><.icon name={@mark} class="size-2.5" /></span>
    </div>
    """
  end

  @doc """
  The filled squares of a 5×5 grid, mirrored left to right so it reads as a
  face-like shape rather than noise. Never empty: a blank tile says nothing.
  """
  def cells(name) do
    bits = :erlang.phash2({:avatar, name}, 1 <<< 15)

    filled =
      for y <- 0..(@size - 1), x <- 0..2, (bits >>> (y * 3 + x) &&& 1) == 1, do: {x, y}

    filled = if filled == [], do: [{2, 2}], else: filled

    filled
    |> Enum.flat_map(fn {x, y} -> Enum.uniq([{x, y}, {@size - 1 - x, y}]) end)
    |> Enum.sort()
  end

  def hue(name), do: :erlang.phash2({:hue, name}, @hues)

  @doc "The icon for what a role is for, or nil when the role says nothing we recognise."
  def mark(role) when is_binary(role) do
    role = String.downcase(role)

    found =
      for {words, icon} <- @marks,
          word <- words,
          {at, _} <- [:binary.match(role, word)],
          do: {at, icon}

    case Enum.min_by(found, &elem(&1, 0), fn -> nil end) do
      nil -> nil
      {_at, icon} -> icon
    end
  end

  def mark(_role), do: nil
end
