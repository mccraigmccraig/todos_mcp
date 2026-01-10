defmodule TodosMcp.DomainHandlerStubTest do
  @moduledoc """
  Tests DomainHandler with stubbed effects (no database).
  """
  use ExUnit.Case, async: true

  use Skuld.Syntax
  alias Skuld.Comp
  alias Skuld.Effects.{Command, Query, Throw}
  alias Skuld.Effects.EctoPersist
  alias TodosMcp.{DomainHandler, DataAccess, Todo}

  alias TodosMcp.Commands.{CreateTodo, UpdateTodo, ToggleTodo, DeleteTodo}
  alias TodosMcp.Queries.{GetTodo, ListTodos}

  describe "CreateTodo command" do
    test "inserts a new todo" do
      cmd = %CreateTodo{title: "Test Todo", description: "A description"}

      {{:ok, todo}, calls} =
        Command.execute(cmd)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> EctoPersist.with_test_handler(fn
          %EctoPersist.Insert{input: cs} ->
            cs |> Ecto.Changeset.apply_changes() |> Map.put(:id, 42)
        end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert todo.id == 42
      assert todo.title == "Test Todo"
      assert todo.description == "A description"

      assert [{:insert, changeset}] = calls
      assert changeset.changes.title == "Test Todo"
    end
  end

  describe "UpdateTodo command" do
    test "updates an existing todo" do
      existing_todo = %Todo{
        id: 1,
        title: "Old Title",
        description: "Old description",
        completed: false,
        priority: :medium,
        tags: []
      }

      cmd = %UpdateTodo{id: 1, title: "New Title"}

      # Stub the DataAccess.get_todo! query
      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo!, %{id: 1}) => existing_todo
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

      assert todo.id == 1
      assert todo.title == "New Title"
      assert todo.description == "Old description"

      assert [{:update, changeset}] = calls
      assert changeset.changes.title == "New Title"
    end
  end

  describe "ToggleTodo command" do
    test "toggles completed status" do
      existing_todo = %Todo{
        id: 1,
        title: "Test",
        completed: false,
        priority: :medium,
        tags: []
      }

      cmd = %ToggleTodo{id: 1}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo!, %{id: 1}) => existing_todo
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
        id: 1,
        title: "To Delete",
        completed: false,
        priority: :medium,
        tags: []
      }

      cmd = %DeleteTodo{id: 1}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo!, %{id: 1}) => existing_todo
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

      assert deleted.id == 1
      assert [{:delete, ^existing_todo}] = calls
    end
  end

  describe "GetTodo query" do
    test "returns todo when found" do
      existing_todo = %Todo{
        id: 1,
        title: "Found",
        completed: false,
        priority: :medium,
        tags: []
      }

      query = %GetTodo{id: 1}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo, %{id: 1}) => existing_todo
      }

      # Queries don't use EctoPersist, so we just need Query stub
      {:ok, todo} =
        Command.execute(query)
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Query.with_test_handler(query_stubs)
        |> Throw.with_handler()
        |> Comp.run!()

      assert todo.id == 1
      assert todo.title == "Found"
    end

    test "returns error when not found" do
      query = %GetTodo{id: 999}

      query_stubs = %{
        Query.key(DataAccess.Impl, :get_todo, %{id: 999}) => nil
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
        %Todo{id: 1, title: "First", completed: false, priority: :medium, tags: []},
        %Todo{id: 2, title: "Second", completed: true, priority: :high, tags: []}
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
end
