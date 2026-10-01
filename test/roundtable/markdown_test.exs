defmodule Roundtable.MarkdownTest do
  @moduledoc """
  Markdown blocks and inline text used by the browser message renderer.
  """
  use ExUnit.Case, async: true

  alias Roundtable.Markdown

  describe "blocks" do
    test "headings lose their hashes" do
      assert Markdown.blocks("## What I changed") == [{:heading, "What I changed"}]
      assert Markdown.blocks("# Top") == [{:heading, "Top"}]
      assert [{:text, "#nothashtag"}] = Markdown.blocks("#nothashtag")
    end

    test "bullets are recognised however they are written" do
      assert Markdown.blocks("- one\n* two\n+ three") == [
               {:bullet, "one"},
               {:bullet, "two"},
               {:bullet, "three"}
             ]
    end

    test "a fence becomes a code block, and its language is kept" do
      assert [{:code, "elixir", ["def run do", "  :ok", "end"]}] =
               Markdown.blocks("```elixir\ndef run do\n  :ok\nend\n```")
    end

    test "an unterminated fence still renders, because a turn can be cut off" do
      assert [{:code, "", ["half a thought"]}] = Markdown.blocks("```\nhalf a thought")
    end

    test "markers inside a fence are left alone" do
      assert [{:code, "", ["# not a heading", "- not a bullet"]}] =
               Markdown.blocks("```\n# not a heading\n- not a bullet\n```")
    end

    test "blank lines are kept, because the shape carries meaning" do
      assert Markdown.blocks("one\n\ntwo") == [{:text, "one"}, :blank, {:text, "two"}]
    end
  end

  describe "inline markers" do
    test "are dropped, not shown" do
      assert Markdown.plain("call `Cart.discount/2` now") == "call Cart.discount/2 now"
      assert Markdown.plain("**important**") == "important"
    end

    test "leave ordinary text alone" do
      assert Markdown.plain("2 * 3 = 6") == "2 * 3 = 6"
    end
  end
end
