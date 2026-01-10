defmodule TodosMcp.DataAccess.ImplTest do
  @moduledoc """
  Tests for DataAccess.Impl with real database (Ecto sandbox).
  Only runs when storage_mode is :database.
  """
  use TodosMcp.DataCase, async: true

  # Skip these tests when not in database mode
  if Application.compile_env(:todos_mcp, :storage_mode, :in_memory) != :database do
    @moduletag :skip
  end

  alias TodosMcp.{Repo, Todo, DataAccess}

  @test_tenant "test-tenant"

  # Helper to create a todo directly in the database
  defp create_todo!(attrs) do
    %Todo{}
    |> Todo.changeset(
      attrs
      |> Map.put(:id, Uniq.UUID.uuid7())
      |> Map.put(:tenant_id, @test_tenant)
    )
    |> Repo.insert!()
  end

  describe "get_todo/1" do
    test "returns {:ok, todo} when found" do
      todo = create_todo!(%{title: "Test Todo"})

      {:ok, result} = DataAccess.Impl.get_todo(%{tenant_id: @test_tenant, id: todo.id})

      assert result.id == todo.id
      assert result.title == "Test Todo"
    end

    test "returns {:error, :not_found} when not found" do
      non_existent_id = Uniq.UUID.uuid7()

      result = DataAccess.Impl.get_todo(%{tenant_id: @test_tenant, id: non_existent_id})

      assert {:error, {:not_found, TodosMcp.Todo, ^non_existent_id}} = result
    end

    test "does not return todos from other tenants" do
      todo = create_todo!(%{title: "Test Todo"})

      result = DataAccess.Impl.get_todo(%{tenant_id: "other-tenant", id: todo.id})

      assert {:error, {:not_found, TodosMcp.Todo, _}} = result
    end
  end

  describe "list_todos/1" do
    test "returns all todos with default options" do
      todo1 = create_todo!(%{title: "First"})
      todo2 = create_todo!(%{title: "Second"})

      {:ok, result} = DataAccess.Impl.list_todos(%{tenant_id: @test_tenant})

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert todo1.id in ids
      assert todo2.id in ids
    end

    test "filters by active (incomplete)" do
      _completed = create_todo!(%{title: "Done", completed: true})
      active = create_todo!(%{title: "Active", completed: false})

      {:ok, result} = DataAccess.Impl.list_todos(%{tenant_id: @test_tenant, filter: :active})

      assert length(result) == 1
      assert hd(result).id == active.id
    end

    test "filters by completed" do
      completed = create_todo!(%{title: "Done", completed: true})
      _active = create_todo!(%{title: "Active", completed: false})

      {:ok, result} = DataAccess.Impl.list_todos(%{tenant_id: @test_tenant, filter: :completed})

      assert length(result) == 1
      assert hd(result).id == completed.id
    end

    test "sorts by title ascending" do
      create_todo!(%{title: "Zebra"})
      create_todo!(%{title: "Apple"})

      {:ok, result} =
        DataAccess.Impl.list_todos(%{tenant_id: @test_tenant, sort_by: :title, sort_order: :asc})

      titles = Enum.map(result, & &1.title)
      assert titles == ["Apple", "Zebra"]
    end

    test "sorts by title descending" do
      create_todo!(%{title: "Apple"})
      create_todo!(%{title: "Zebra"})

      {:ok, result} =
        DataAccess.Impl.list_todos(%{tenant_id: @test_tenant, sort_by: :title, sort_order: :desc})

      titles = Enum.map(result, & &1.title)
      assert titles == ["Zebra", "Apple"]
    end

    test "sorts by priority" do
      create_todo!(%{title: "Low", priority: :low})
      create_todo!(%{title: "High", priority: :high})
      create_todo!(%{title: "Medium", priority: :medium})

      {:ok, result} =
        DataAccess.Impl.list_todos(%{
          tenant_id: @test_tenant,
          sort_by: :priority,
          sort_order: :asc
        })

      priorities = Enum.map(result, & &1.priority)
      assert priorities == [:high, :low, :medium]
    end

    test "returns empty list when no todos" do
      {:ok, result} = DataAccess.Impl.list_todos(%{tenant_id: @test_tenant})

      assert result == []
    end

    test "only returns todos for the specified tenant" do
      create_todo!(%{title: "My Todo"})

      {:ok, result} = DataAccess.Impl.list_todos(%{tenant_id: "other-tenant"})

      assert result == []
    end
  end

  describe "list_incomplete/1" do
    test "returns only incomplete todos" do
      incomplete1 = create_todo!(%{title: "Todo 1", completed: false})
      incomplete2 = create_todo!(%{title: "Todo 2", completed: false})
      _completed = create_todo!(%{title: "Done", completed: true})

      {:ok, result} = DataAccess.Impl.list_incomplete(%{tenant_id: @test_tenant})

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert incomplete1.id in ids
      assert incomplete2.id in ids
    end

    test "returns empty list when all completed" do
      create_todo!(%{title: "Done 1", completed: true})
      create_todo!(%{title: "Done 2", completed: true})

      {:ok, result} = DataAccess.Impl.list_incomplete(%{tenant_id: @test_tenant})

      assert result == []
    end
  end

  describe "list_completed/1" do
    test "returns only completed todos" do
      _incomplete = create_todo!(%{title: "Todo", completed: false})
      completed1 = create_todo!(%{title: "Done 1", completed: true})
      completed2 = create_todo!(%{title: "Done 2", completed: true})

      {:ok, result} = DataAccess.Impl.list_completed(%{tenant_id: @test_tenant})

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert completed1.id in ids
      assert completed2.id in ids
    end

    test "returns empty list when none completed" do
      create_todo!(%{title: "Todo 1", completed: false})
      create_todo!(%{title: "Todo 2", completed: false})

      {:ok, result} = DataAccess.Impl.list_completed(%{tenant_id: @test_tenant})

      assert result == []
    end
  end

  describe "search_todos/1" do
    test "finds todos matching title" do
      match1 = create_todo!(%{title: "Buy milk"})
      match2 = create_todo!(%{title: "Buy eggs"})
      _no_match = create_todo!(%{title: "Walk dog"})

      {:ok, result} =
        DataAccess.Impl.search_todos(%{tenant_id: @test_tenant, query: "Buy", limit: 10})

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert match1.id in ids
      assert match2.id in ids
    end

    test "finds todos matching description" do
      match = create_todo!(%{title: "Task", description: "Remember to buy milk"})
      _no_match = create_todo!(%{title: "Other", description: "Walk the dog"})

      {:ok, result} =
        DataAccess.Impl.search_todos(%{tenant_id: @test_tenant, query: "milk", limit: 10})

      assert length(result) == 1
      assert hd(result).id == match.id
    end

    test "search is case insensitive" do
      match = create_todo!(%{title: "BUY MILK"})

      {:ok, result} =
        DataAccess.Impl.search_todos(%{tenant_id: @test_tenant, query: "buy milk", limit: 10})

      assert length(result) == 1
      assert hd(result).id == match.id
    end

    test "respects limit" do
      for i <- 1..5, do: create_todo!(%{title: "Task #{i}"})

      {:ok, result} =
        DataAccess.Impl.search_todos(%{tenant_id: @test_tenant, query: "Task", limit: 3})

      assert length(result) == 3
    end

    test "returns empty list when no matches" do
      create_todo!(%{title: "Something else"})

      {:ok, result} =
        DataAccess.Impl.search_todos(%{tenant_id: @test_tenant, query: "nonexistent", limit: 10})

      assert result == []
    end
  end

  describe "get_stats/1" do
    test "returns correct counts" do
      create_todo!(%{title: "Active 1", completed: false})
      create_todo!(%{title: "Active 2", completed: false})
      create_todo!(%{title: "Done 1", completed: true})

      {:ok, result} = DataAccess.Impl.get_stats(%{tenant_id: @test_tenant})

      assert result == %{total: 3, active: 2, completed: 1}
    end

    test "returns zeros when no todos" do
      {:ok, result} = DataAccess.Impl.get_stats(%{tenant_id: @test_tenant})

      assert result == %{total: 0, active: 0, completed: 0}
    end

    test "handles all active" do
      create_todo!(%{title: "Active 1", completed: false})
      create_todo!(%{title: "Active 2", completed: false})

      {:ok, result} = DataAccess.Impl.get_stats(%{tenant_id: @test_tenant})

      assert result == %{total: 2, active: 2, completed: 0}
    end

    test "handles all completed" do
      create_todo!(%{title: "Done 1", completed: true})
      create_todo!(%{title: "Done 2", completed: true})

      {:ok, result} = DataAccess.Impl.get_stats(%{tenant_id: @test_tenant})

      assert result == %{total: 2, active: 0, completed: 2}
    end
  end
end
