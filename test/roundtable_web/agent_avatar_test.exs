defmodule RoundtableWeb.AgentAvatarTest do
  use RoundtableWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias RoundtableWeb.AgentAvatar

  test "a name always draws the same picture, and different names differ" do
    assert AgentAvatar.cells("ada") == AgentAvatar.cells("ada")
    assert render("ada", nil) == render("ada", nil)

    pictures = for name <- ~w(ada linus grace alan barbara ken), do: AgentAvatar.cells(name)
    assert length(Enum.uniq(pictures)) == 6
  end

  test "the pattern is mirrored and never blank" do
    for name <- ["", "a", "qa", "dev-codex"] do
      cells = AgentAvatar.cells(name)
      assert cells != []
      assert Enum.all?(cells, fn {x, y} -> {4 - x, y} in cells end)
    end
  end

  test "the role's leading keyword chooses the mark" do
    assert AgentAvatar.mark("Developer on Roundtable, working for @captan. Tests ship with it.") ==
             "hero-code-bracket-mini"

    assert AgentAvatar.mark("QA for Roundtable, working for @captan") == "hero-check-badge-mini"

    assert AgentAvatar.mark("Product owner, hands work to developers") ==
             "hero-clipboard-document-list-mini"

    assert AgentAvatar.mark("you are the team captan that leads the agents") == "hero-star-mini"
    assert AgentAvatar.mark("Writes release notes") == nil
    assert AgentAvatar.mark(nil) == nil
  end

  test "a keyword matches whole words only, and still reaches its longer forms" do
    assert AgentAvatar.mark("keep an eye ahead of the build") == nil
    assert AgentAvatar.mark("keep it up to latest at all times") == nil
    assert AgentAvatar.mark("engineer") == "hero-code-bracket-mini"
    assert AgentAvatar.mark("code review and then some") == "hero-check-badge-mini"
    assert AgentAvatar.mark("team lead on the rebuild") == "hero-star-mini"
    assert AgentAvatar.mark("verification and orchestration") == "hero-check-badge-mini"
    assert AgentAvatar.mark("orchestrator of the room") == "hero-star-mini"
  end

  test "it names the agent for people who cannot see the picture" do
    html = render("ada", "Reviewer")
    assert html =~ ~s(aria-label="ada")
    assert html =~ "hero-check-badge-mini"
    refute render("ada", "Writes release notes") =~ "avatar-mark"
  end

  defp render(name, role),
    do: render_component(&AgentAvatar.agent_avatar/1, name: name, role: role, provider: "claude")
end
