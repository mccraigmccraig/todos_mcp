defmodule TodosMcp.DomainHandlerStubTest do
  @moduledoc """
  Tests DomainHandler with stubbed effects (no database).
  """
  use ExUnit.Case, async: true

  use Skuld.Syntax
  alias Skuld.Comp
  alias Skuld.Effects.{Command, Query, Fresh, Throw, Reader}
  alias Skuld.Effects.EctoPersist
  alias TodosMcp.{DomainHandler, DataAccess, Todo, CommandContext}

  # Fixed UUIDs for testing
  @uuid1 "550e8400-e29b-41d4-a716-446655440001"
  @uuid2 "550e8400-e29b-41d4-a716-446655440002"
  @uuid_not_found "550e8400-e29b-41d4-a716-446655449999"

  # Default tenant for tests
  @test_tenant "test-tenant"

  alias TodosMcp.Commands.{
    CreateTodo,
    UpdateTodo,
    ToggleTodo,
    DeleteTodo,
    CompleteAll,
    ClearCompleted
  }

  alias TodosMcp.Queries.{GetTodo, ListTodos, SearchTodos, GetStats}

  # Helper to run operations through the domain handler with stubbed effects.
  # Options:
  #   - queries: map of Query.key(...) => result for Query.with_test_handler
  #   - persist: function for EctoPersist.with_test_handler
  #   - fresh: keyword opts for Fresh.with_test_handler (e.g., namespace: "test")
  #   - tenant_id: tenant for CommandContext (defaults to @test_tenant)
  defp run(operation, opts) do
    queries = Keyword.get(opts, :queries, %{})
    persist = Keyword.get(opts, :persist)
    fresh = Keyword.get(opts, :fresh)
    tenant_id = Keyword.get(opts, :tenant_id, @test_tenant)

    Command.execute(operation)
    |> Command.with_handler(&DomainHandler.handle/1)
    |> Reader.with_handler(%CommandContext{tenant_id: tenant_id}, tag: CommandContext)
    |> then(fn c ->
      if map_size(queries) > 0, do: Query.with_test_handler(c, queries), else: c
    end)
    |> then(fn c -> if persist, do: EctoPersist.with_test_handler(c, persist), else: c end)
    |> then(fn c -> if fresh, do: Fresh.with_test_handler(c, fresh), else: c end)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  describe "CreateTodo command" do
    test "inserts a new todo with generated UUID" do
      {{:ok, todo}, calls} =
        run(%CreateTodo{title: "Test Todo", description: "A description"},
          fresh: [namespace: "test-create-todo"],
          persist: fn %EctoPersist.Insert{input: cs} -> Ecto.Changeset.apply_changes(cs) end
        )

      # ID should be a UUID string (deterministic from namespace)
      assert is_binary(todo.id)
      assert String.length(todo.id) == 36
      assert todo.title == "Test Todo"
      assert todo.description == "A description"

      assert [{:insert, changeset}] = calls
      assert changeset.changes.title == "Test Todo"
      assert changeset.changes.id == todo.id
    end
  end

  describe "UpdateTodo command" do
    test "updates an existing todo" do
      existing = %Todo{
        id: @uuid1,
        tenant_id: @test_tenant,
        title: "Old Title",
        description: "Old description",
        completed: false,
        priority: :medium,
        tags: []
      }

      {{:ok, todo}, calls} =
        run(%UpdateTodo{id: @uuid1, title: "New Title"},
          queries: %{
            Query.key(DataAccess.Ecto, :get_todo, %{tenant_id: @test_tenant, id: @uuid1}) =>
              {:ok, existing}
          },
          persist: fn %EctoPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs) end
        )

      assert todo.id == @uuid1
      assert todo.title == "New Title"
      assert todo.description == "Old description"

      assert [{:update, changeset}] = calls
      assert changeset.changes.title == "New Title"
    end
  end

  describe "ToggleTodo command" do
    test "toggles completed status" do
      existing = %Todo{
        id: @uuid1,
        tenant_id: @test_tenant,
        title: "Test",
        completed: false,
        priority: :medium,
        tags: []
      }

      {{:ok, todo}, calls} =
        run(%ToggleTodo{id: @uuid1},
          queries: %{
            Query.key(DataAccess.Ecto, :get_todo, %{tenant_id: @test_tenant, id: @uuid1}) =>
              {:ok, existing}
          },
          persist: fn %EctoPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs) end
        )

      assert todo.completed == true
      assert [{:update, _}] = calls
    end
  end

  describe "DeleteTodo command" do
    test "deletes an existing todo" do
      existing = %Todo{
        id: @uuid1,
        tenant_id: @test_tenant,
        title: "To Delete",
        completed: false,
        priority: :medium,
        tags: []
      }

      {{:ok, deleted}, calls} =
        run(%DeleteTodo{id: @uuid1},
          queries: %{
            Query.key(DataAccess.Ecto, :get_todo, %{tenant_id: @test_tenant, id: @uuid1}) =>
              {:ok, existing}
          },
          persist: fn %EctoPersist.Delete{input: s} -> {:ok, s} end
        )

      assert deleted.id == @uuid1
      assert [{:delete, ^existing}] = calls
    end
  end

  describe "GetTodo query" do
    test "returns todo when found" do
      existing = %Todo{
        id: @uuid1,
        tenant_id: @test_tenant,
        title: "Found",
        completed: false,
        priority: :medium,
        tags: []
      }

      {:ok, todo} =
        run(%GetTodo{id: @uuid1},
          queries: %{
            Query.key(DataAccess.Ecto, :get_todo, %{tenant_id: @test_tenant, id: @uuid1}) =>
              {:ok, existing}
          }
        )

      assert todo.id == @uuid1
      assert todo.title == "Found"
    end

    test "returns error when not found" do
      result =
        run(%GetTodo{id: @uuid_not_found},
          queries: %{
            Query.key(DataAccess.Ecto, :get_todo, %{tenant_id: @test_tenant, id: @uuid_not_found}) =>
              {:error, {:not_found, Todo, @uuid_not_found}}
          }
        )

      assert result == {:error, :not_found}
    end
  end

  describe "ListTodos query" do
    test "returns all todos with default options" do
      todos = [
        %Todo{
          id: @uuid1,
          tenant_id: @test_tenant,
          title: "First",
          completed: false,
          priority: :medium,
          tags: []
        },
        %Todo{
          id: @uuid2,
          tenant_id: @test_tenant,
          title: "Second",
          completed: true,
          priority: :high,
          tags: []
        }
      ]

      {:ok, result} =
        run(%ListTodos{},
          queries: %{
            Query.key(DataAccess.Ecto, :list_todos, %{
              tenant_id: @test_tenant,
              filter: :all,
              sort_by: :inserted_at,
              sort_order: :desc
            }) => {:ok, todos}
          }
        )

      assert length(result) == 2
      assert Enum.map(result, & &1.title) == ["First", "Second"]
    end
  end

  describe "CompleteAll command" do
    test "marks all incomplete todos as completed" do
      incomplete_todos = [
        %Todo{
          id: @uuid1,
          tenant_id: @test_tenant,
          title: "First",
          completed: false,
          priority: :medium,
          tags: []
        },
        %Todo{
          id: @uuid2,
          tenant_id: @test_tenant,
          title: "Second",
          completed: false,
          priority: :high,
          tags: []
        }
      ]

      {{:ok, result}, calls} =
        run(%CompleteAll{},
          queries: %{
            Query.key(DataAccess.Ecto, :list_incomplete, %{tenant_id: @test_tenant}) =>
              {:ok, incomplete_todos}
          },
          persist: fn %EctoPersist.UpdateAll{entries: entries} -> {length(entries), nil} end
        )

      assert result == %{updated: 2}
      assert [{:update_all, {Todo, changesets, []}}] = calls
      assert length(changesets) == 2
      # All changesets should set completed: true
      assert Enum.all?(changesets, fn cs -> cs.changes.completed == true end)
    end

    test "returns zero when no incomplete todos" do
      {{:ok, result}, calls} =
        run(%CompleteAll{},
          queries: %{
            Query.key(DataAccess.Ecto, :list_incomplete, %{tenant_id: @test_tenant}) => {:ok, []}
          },
          persist: fn %EctoPersist.UpdateAll{entries: entries} -> {length(entries), nil} end
        )

      assert result == %{updated: 0}
      assert [{:update_all, {Todo, [], []}}] = calls
    end
  end

  describe "ClearCompleted command" do
    test "deletes all completed todos" do
      completed_todos = [
        %Todo{
          id: @uuid1,
          tenant_id: @test_tenant,
          title: "Done 1",
          completed: true,
          priority: :medium,
          tags: []
        },
        %Todo{
          id: @uuid2,
          tenant_id: @test_tenant,
          title: "Done 2",
          completed: true,
          priority: :low,
          tags: []
        }
      ]

      {{:ok, result}, calls} =
        run(%ClearCompleted{},
          queries: %{
            Query.key(DataAccess.Ecto, :list_completed, %{tenant_id: @test_tenant}) =>
              {:ok, completed_todos}
          },
          persist: fn %EctoPersist.DeleteAll{entries: entries} -> {length(entries), nil} end
        )

      assert result == %{deleted: 2}
      assert [{:delete_all, {Todo, ^completed_todos, []}}] = calls
    end

    test "returns zero when no completed todos" do
      {{:ok, result}, calls} =
        run(%ClearCompleted{},
          queries: %{
            Query.key(DataAccess.Ecto, :list_completed, %{tenant_id: @test_tenant}) => {:ok, []}
          },
          persist: fn %EctoPersist.DeleteAll{entries: entries} -> {length(entries), nil} end
        )

      assert result == %{deleted: 0}
      assert [{:delete_all, {Todo, [], []}}] = calls
    end
  end

  describe "SearchTodos query" do
    test "searches todos by query string" do
      matching_todos = [
        %Todo{
          id: @uuid1,
          tenant_id: @test_tenant,
          title: "Buy milk",
          completed: false,
          priority: :medium,
          tags: []
        },
        %Todo{
          id: @uuid2,
          tenant_id: @test_tenant,
          title: "Buy eggs",
          completed: false,
          priority: :low,
          tags: []
        }
      ]

      {:ok, result} =
        run(%SearchTodos{query: "Buy", limit: 10},
          queries: %{
            Query.key(DataAccess.Ecto, :search_todos, %{
              tenant_id: @test_tenant,
              query: "Buy",
              limit: 10
            }) => {:ok, matching_todos}
          }
        )

      assert length(result) == 2
      assert Enum.all?(result, fn t -> String.contains?(t.title, "Buy") end)
    end

    test "returns empty list when no matches" do
      {:ok, result} =
        run(%SearchTodos{query: "nonexistent"},
          queries: %{
            Query.key(DataAccess.Ecto, :search_todos, %{
              tenant_id: @test_tenant,
              query: "nonexistent",
              limit: 20
            }) => {:ok, []}
          }
        )

      assert result == []
    end
  end

  describe "GetStats query" do
    test "returns todo statistics" do
      {:ok, result} =
        run(%GetStats{},
          queries: %{
            Query.key(DataAccess.Ecto, :get_stats, %{tenant_id: @test_tenant}) =>
              {:ok, %{total: 10, active: 6, completed: 4}}
          }
        )

      assert result == %{total: 10, active: 6, completed: 4}
    end

    test "returns zeros when no todos" do
      {:ok, result} =
        run(%GetStats{},
          queries: %{
            Query.key(DataAccess.Ecto, :get_stats, %{tenant_id: @test_tenant}) =>
              {:ok, %{total: 0, active: 0, completed: 0}}
          }
        )

      assert result == %{total: 0, active: 0, completed: 0}
    end
  end
end
