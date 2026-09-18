defmodule Roundtable.MarkdownTest do
  @moduledoc """
  What agents actually write, and how it has to read.

  The wrapping tests matter most: breaking mid-word to fill a column made
  every reply look corrupted, and no amount of styling fixes that.
  """
  use ExUnit.Case, async: true

  alias Roundtable.Markdown

  describe "wrapping" do
    test "breaks between words, not through them" do
      assert Markdown.wrap("the test does not cover the boundary", 20) == [
               "the test does not",
               "cover the boundary"
             ]
    end

    test "every line fits" do
      text = "Roundtable keeps one conversation for a human and several coding agents."

      for width <- [12, 20, 37, 80] do
        for line <- Markdown.wrap(text, width) do
          assert String.length(line) <= width, "#{inspect(line)} is wider than #{width}"
        end
      end
    end

    test "a word longer than the line is broken, because the alternative overflows" do
      path = String.duplicate("a", 25)
      lines = Markdown.wrap(path, 10)

      assert Enum.all?(lines, &(String.length(&1) <= 10))
      assert Enum.join(lines) == path
    end

    test "nothing to wrap is still one line" do
      assert Markdown.wrap("", 20) == [""]
      assert Markdown.wrap("   ", 20) == [""]
      assert Markdown.wrap("anything", 0) == [""]
    end
  end

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
