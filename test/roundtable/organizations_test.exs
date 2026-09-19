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

  describe "a project's folder and brief" do
    test "a folder is optional, because not every project is a checkout" do
      assert {:ok, organization} = Chat.create_organization(%{"name" => "Marketing Co"})
      assert organization.directory == nil
      assert organization.context == ""
    end

    test "a folder that is named has to exist" do
      assert {:error, changeset} =
               Chat.create_organization(%{"name" => "Ghost", "directory" => "/no/such/place"})

      assert %{directory: ["must be an existing absolute directory"]} = errors_on(changeset)
    end

    test "the project brief reaches a participant's turn, alongside the room's" do
      {:ok, organization} =
        Chat.create_organization(%{
          "name" => "Roundtable app",
          "context" => "One local workspace for a human and named agents."
        })

      {:ok, room} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "context" => "Ship the coordination core.",
          "organization_id" => organization.id
        })

      {:ok, agent} =
        Chat.create_agent(room.id, %{
          "name" => "ada",
          "provider" => "codex",
          "directory" => File.cwd!()
        })

      {:ok, message} = Chat.post(room.id, "@ada have a look")
      run = Repo.one!(from r in Roundtable.Chat.Run, where: r.message_id == ^message.id)

      {prompt, _until} = Chat.prompt(Chat.agent!(agent.id), run)

      assert prompt =~ "Roundtable app"
      assert prompt =~ "One local workspace for a human and named agents."
      assert prompt =~ "Ship the coordination core."
    end

    test "a project with no brief adds nothing to the turn" do
      {:ok, organization} = Chat.create_organization(%{"name" => "Quiet"})

      {:ok, room} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => organization.id
        })

      {:ok, agent} =
        Chat.create_agent(room.id, %{
          "name" => "ada",
          "provider" => "codex",
          "directory" => File.cwd!()
        })

      {:ok, message} = Chat.post(room.id, "@ada have a look")
      run = Repo.one!(from r in Roundtable.Chat.Run, where: r.message_id == ^message.id)

      {prompt, _until} = Chat.prompt(Chat.agent!(agent.id), run)

      refute prompt =~ "The whole project is working on"
    end
  end

  describe "teams talking to each other" do
    setup do
      {:ok, alpha} = Chat.create_organization(%{"name" => "Alpha"})
      {:ok, beta} = Chat.create_organization(%{"name" => "Beta"})

      {:ok, alpha_eng} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => alpha.id
        })

      {:ok, alpha_sales} =
        Chat.create_room(%{
          "name" => "Sales",
          "directory" => File.cwd!(),
          "organization_id" => alpha.id
        })

      {:ok, beta_eng} =
        Chat.create_room(%{
          "name" => "Engineering",
          "directory" => File.cwd!(),
          "organization_id" => beta.id
        })

      %{
        alpha: alpha,
        beta: beta,
        alpha_eng: alpha_eng,
        alpha_sales: alpha_sales,
        beta_eng: beta_eng
      }
    end

    test "reach the team of that name in their own project", ctx do
      assert {:ok, found} = Chat.find_room("engineering", ctx.alpha.id)
      assert found.id == ctx.alpha_eng.id

      assert {:ok, found} = Chat.find_room("engineering", ctx.beta.id)
      assert found.id == ctx.beta_eng.id
    end

    test "cannot reach a team in another project", ctx do
      assert {:error, reason} = Chat.find_room("sales", ctx.beta.id)
      assert reason =~ "No team called sales in this project"
    end

    test "an ask crosses rooms inside one project", ctx do
      {:ok, _} =
        Chat.create_agent(ctx.alpha_sales.id, %{
          "name" => "grace",
          "provider" => "codex",
          "directory" => File.cwd!()
        })

      assert {:ok, _request} =
               Chat.request_from_room(
                 "ask",
                 ctx.alpha_eng.id,
                 "sales/grace",
                 "what is the price?"
               )
    end

    test "an ask does not cross into another project", ctx do
      {:ok, _} =
        Chat.create_agent(ctx.alpha_sales.id, %{
          "name" => "grace",
          "provider" => "codex",
          "directory" => File.cwd!()
        })

      assert {:error, reason} =
               Chat.request_from_room("ask", ctx.beta_eng.id, "sales/grace", "what is the price?")

      assert reason =~ "No team called sales in this project"
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
