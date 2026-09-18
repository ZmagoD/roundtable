defmodule RoundtableWeb.Layouts do
  use RoundtableWeb, :html
  embed_templates "layouts/*"
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end
end
