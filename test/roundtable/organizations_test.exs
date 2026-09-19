defmodule Roundtable.OrganizationsTest do
  use Roundtable.DataCase, async: false
  alias Roundtable.Chat

  describe "the organization every existing room was put in" do
    test "is there, and is the one a room lands in when nobody said which" do
      assert %{name: "Existing workspace"} = existing = Chat.default_organization()

      {:ok, room} = Chat.create_room(%{"name" => "Engineering", "directory" => File.cwd!()})

      assert room.organization_id == existing.id
    end

    test "the team builder puts its room in the same place" do
      {:ok, room} =
        Chat.build_team(%{
          "name" => "Product",
          "directory" => File.cwd!(),
          "context" => "Ship the thing.",
          "provider" => "claude"
        })

      assert room.organization_id == Chat.default_organization().id
    end
  end

  describe "two projects" do
    setup do
      {:ok, alpha} = Chat.create_organization(%{"name" => "Alpha"})
      {:ok, beta} = Chat.create_organization(%{"name" => "Beta"})
      %{alpha: alpha, beta: beta}
    end

    test "can each have a team with the same name", ctx do
      {:ok, one} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => ctx.alpha.id
        })

      {:ok, two} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => ctx.beta.id
        })

      assert one.id != two.id
      assert one.name == two.name
    end

    test "list only their own teams", ctx do
      {:ok, _} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => ctx.alpha.id
        })

      {:ok, _} =
        Chat.create_room(%{
          "name" => "Marketing",
          "directory" => File.cwd!(),
          "organization_id" => ctx.beta.id
        })

      assert ["Engineering"] = Enum.map(Chat.rooms(ctx.alpha.id), & &1.name)
      assert ["Marketing"] = Enum.map(Chat.rooms(ctx.beta.id), & &1.name)
    end

    test "cannot share a name themselves" do
      assert {:error, changeset} = Chat.create_organization(%{"name" => "Alpha"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "renaming a project" do
    test "keeps its teams" do
      {:ok, organization} = Chat.create_organization(%{"name" => "Alpha"})

      {:ok, room} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => organization.id
        })

      {:ok, renamed} = Chat.update_organization(organization.id, %{"name" => "Alpha Co"})

      assert renamed.name == "Alpha Co"
      assert [%{id: kept}] = Chat.rooms(organization.id)
      assert kept == room.id
    end
  end
end
