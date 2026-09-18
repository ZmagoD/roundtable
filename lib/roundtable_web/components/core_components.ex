defmodule RoundtableWeb.CoreComponents do
  @moduledoc """
  The components the room UI actually uses.

  Pared back to the two that earn their place. Anything a single template needs
  belongs in that template until a second one wants it.
  """
  use Phoenix.Component

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :class, :string, default: nil
  attr :id, :string, default: nil
  attr :options, :list, default: []

  attr :rest, :global,
    include: ~w(autofocus required maxlength pattern placeholder rows disabled autocomplete list)

  def input(assigns) do
    assigns = assign(assigns, :input_id, assigns.id || assigns.field.id)

    ~H"""
    <div class="input-field">
      <label :if={@label} for={@input_id}>{@label}</label>
      <%= case @type do %>
        <% "textarea" -> %>
          <textarea id={@input_id} name={@field.name} class={@class} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
        <% "select" -> %>
          <select id={@input_id} name={@field.name} class={@class} {@rest}>{Phoenix.HTML.Form.options_for_select(
            @options,
            @field.value
          )}</select>
        <% _ -> %>
          <input
            id={@input_id}
            type={@type}
            name={@field.name}
            value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
            class={@class}
            {@rest}
          />
      <% end %>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :class, :any, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  attr :body, :string, required: true

  @doc """
  A message body, rendered as the Markdown agents actually write.

  Same parser the terminal client uses, so a reply reads the same in both. The
  text is interpolated rather than injected as HTML: an agent's output is not
  trusted markup, and a room is full of other people's output.
  """
  def message(assigns) do
    assigns = assign(assigns, :blocks, Roundtable.Markdown.blocks(assigns.body))

    ~H"""
    <div class="message-text">
      <%= for block <- @blocks do %>
        <%= case block do %>
          <% {:heading, text} -> %>
            <h4>{Roundtable.Markdown.plain(text)}</h4>
          <% {:bullet, text} -> %>
            <p class="message-bullet">{Roundtable.Markdown.plain(text)}</p>
          <% {:code, _language, lines} -> %>
            <pre><code>{Enum.join(lines, "\n")}</code></pre>
          <% {:text, text} -> %>
            <p>{Roundtable.Markdown.plain(text)}</p>
          <% :blank -> %>
        <% end %>
      <% end %>
    </div>
    """
  end
end
