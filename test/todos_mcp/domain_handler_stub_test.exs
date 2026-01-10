defmodule TodosMcp.DomainHandlerStubTest do
  @moduledoc """
  Tests DomainHandler with stubbed effects (no database).
  """
  use ExUnit.Case, async: true

  use Skuld.Syntax
  alias Skuld.Comp
  alias Skuld.Effects.{Command, Query, Fresh, Throw}
  alias Skuld.Effects.EctoPersist
  alias TodosMcp.{DomainHandler, DataAccess, Todo}

  # Fixed UUIDs for testing
  @uuid1 "550e8400-e29b-41d4-a716-446655440001"
  @uuid2 "550e8400-e29b-41d4-a716-446655440002"
  @uuid_not_found "550e8400-e29b-41d4-a716-446655449999"

  alias TodosMcp.Commands.{
    CreateTodo,
    UpdateTodo,
    ToggleTodo,
    DeleteTodo,
    CompleteAll,
    ClearCompleted
  }

  alias TodosMcp.Queries.{GetTodo, ListTodos, SearchTodos, GetStats}

  describe "CreateTodo command" do
    test "inserts a new todo with generated UUID" do
      cmd = %CreateTodo{title: "Test Todo", description: "A description"}

      # Use a fixed namespace for deterministic UUID generation
      namespace = "test-create-todo"

      {{:ok, todo}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.Insert{input: cs} -> Ecto.Changeset.apply_changes(cs)
        end)
        |> Fresh.with_test_handler(namespace: namespace)
        |> Throw.with_handler()
        |> Comp.run!()

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
      existing_todo = %Todo{
        id: @uuid1,
        title: "Old Title",
        description: "Old description",
        completed: false,
        priority: :medium,
        tags: []
      }

      cmd = %UpdateTodo{id: @uuid1, title: "New Title"}

      # Stub the DataAccess.get_todo! query
      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo!, %{id: @uuid1}) => existing_todo
      }

      {{:ok, todo}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert todo.id == @uuid1
      assert todo.title == "New Title"
      assert todo.description == "Old description"

      assert [{:update, changeset}] = calls
      assert changeset.changes.title == "New Title"
    end
  end

  describe "ToggleTodo command" do
    test "toggles completed status" do
      existing_todo = %Todo{
        id: @uuid1,
        title: "Test",
        completed: false,
        priority: :medium,
        tags: []
      }

      cmd = %ToggleTodo{id: @uuid1}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo!, %{id: @uuid1}) => existing_todo
      }

      {{:ok, todo}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert todo.completed == true
      assert [{:update, _}] = calls
    end
  end

  describe "DeleteTodo command" do
    test "deletes an existing todo" do
      existing_todo = %Todo{
        id: @uuid1,
        title: "To Delete",
        completed: false,
        priority: :medium,
        tags: []
      }

      cmd = %DeleteTodo{id: @uuid1}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo!, %{id: @uuid1}) => existing_todo
      }

      {{:ok, deleted}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.Delete{input: s} -> {:ok, s}
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert deleted.id == @uuid1
      assert [{:delete, ^existing_todo}] = calls
    end
  end

  describe "GetTodo query" do
    test "returns todo when found" do
      existing_todo = %Todo{
        id: @uuid1,
        title: "Found",
        completed: false,
        priority: :medium,
        tags: []
      }

      query = %GetTodo{id: @uuid1}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo, %{id: @uuid1}) => existing_todo
      }

      # Queries don't use EctoPersist, so we just need Query stub
      {:ok, todo} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert todo.id == @uuid1
      assert todo.title == "Found"
    end

    test "returns error when not found" do
      query = %GetTodo{id: @uuid_not_found}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo, %{id: @uuid_not_found}) => nil
      }

      result =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:error, :not_found}
    end
  end

  describe "ListTodos query" do
    test "returns all todos with default options" do
      todos = [
        %Todo{id: @uuid1, title: "First", completed: false, priority: :medium, tags: []},
        %Todo{id: @uuid2, title: "Second", completed: true, priority: :high, tags: []}
      ]

      query = %ListTodos{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :list_todos, %{
          filter: :all,
          sort_by: :inserted_at,
          sort_order: :desc
        }) => todos
      }

      {:ok, result} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert length(result) == 2
      assert Enum.map(result, & &1.title) == ["First", "Second"]
    end
  end

  describe "CompleteAll command" do
    test "marks all incomplete todos as completed" do
      incomplete_todos = [
        %Todo{id: @uuid1, title: "First", completed: false, priority: :medium, tags: []},
        %Todo{id: @uuid2, title: "Second", completed: false, priority: :high, tags: []}
      ]

      cmd = %CompleteAll{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :list_incomplete, %{}) => incomplete_todos
      }

      {{:ok, result}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.UpdateAll{entries: entries} -> {length(entries), nil}
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{updated: 2}
      assert [{:update_all, {Todo, changesets, []}}] = calls
      assert length(changesets) == 2
      # All changesets should set completed: true
      assert Enum.all?(changesets, fn cs -> cs.changes.completed == true end)
    end

    test "returns zero when no incomplete todos" do
      cmd = %CompleteAll{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :list_incomplete, %{}) => []
      }

      {{:ok, result}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.UpdateAll{entries: entries} -> {length(entries), nil}
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{updated: 0}
      assert [{:update_all, {Todo, [], []}}] = calls
    end
  end

  describe "ClearCompleted command" do
    test "deletes all completed todos" do
      completed_todos = [
        %Todo{id: @uuid1, title: "Done 1", completed: true, priority: :medium, tags: []},
        %Todo{id: @uuid2, title: "Done 2", completed: true, priority: :low, tags: []}
      ]

      cmd = %ClearCompleted{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :list_completed, %{}) => completed_todos
      }

      {{:ok, result}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.DeleteAll{entries: entries} -> {length(entries), nil}
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{deleted: 2}
      assert [{:delete_all, {Todo, ^completed_todos, []}}] = calls
    end

    test "returns zero when no completed todos" do
      cmd = %ClearCompleted{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :list_completed, %{}) => []
      }

      {{:ok, result}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.DeleteAll{entries: entries} -> {length(entries), nil}
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{deleted: 0}
      assert [{:delete_all, {Todo, [], []}}] = calls
    end
  end

  describe "SearchTodos query" do
    test "searches todos by query string" do
      matching_todos = [
        %Todo{id: @uuid1, title: "Buy milk", completed: false, priority: :medium, tags: []},
        %Todo{id: @uuid2, title: "Buy eggs", completed: false, priority: :low, tags: []}
      ]

      query = %SearchTodos{query: "Buy", limit: 10}

      query_stubs = %{
        Query.key(DataAccess.Impl, :search_todos, %{query: "Buy", limit: 10}) => matching_todos
      }

      {:ok, result} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert length(result) == 2
      assert Enum.all?(result, fn t -> String.contains?(t.title, "Buy") end)
    end

    test "returns empty list when no matches" do
      query = %SearchTodos{query: "nonexistent"}

      query_stubs = %{
        Query.key(DataAccess.Impl, :search_todos, %{query: "nonexistent", limit: 20}) => []
      }

      {:ok, result} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == []
    end
  end

  describe "GetStats query" do
    test "returns todo statistics" do
      stats = %{total: 10, active: 6, completed: 4}

      query = %GetStats{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_stats, %{}) => stats
      }

      {:ok, result} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{total: 10, active: 6, completed: 4}
    end

    test "returns zeros when no todos" do
      stats = %{total: 0, active: 0, completed: 0}

      query = %GetStats{}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_stats, %{}) => stats
      }

      {:ok, result} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{total: 0, active: 0, completed: 0}
    end
  end
end
