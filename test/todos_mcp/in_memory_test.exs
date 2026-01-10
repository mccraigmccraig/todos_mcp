defmodule TodosMcp.InMemoryTest do
  use ExUnit.Case, async: false

  alias TodosMcp.{InMemoryStore, Run}
  alias TodosMcp.Commands.{CreateTodo, ToggleTodo, DeleteTodo, CompleteAll, ClearCompleted}
  alias TodosMcp.Queries.{ListTodos, GetTodo, GetStats}

  setup do
    # Clear the store before each test (it's started by the application)
    InMemoryStore.clear()
    :ok
  end

  describe "in-memory storage mode" do
    test "create todo" do
      {:ok, todo} = Run.execute(%CreateTodo{title: "Test todo"}, mode: :in_memory)

      assert todo.title == "Test todo"
      assert todo.id != nil
      assert todo.completed == false
    end

    test "list todos" do
      {:ok, _} = Run.execute(%CreateTodo{title: "First"}, mode: :in_memory)
      {:ok, _} = Run.execute(%CreateTodo{title: "Second"}, mode: :in_memory)

      {:ok, todos} = Run.execute(%ListTodos{}, mode: :in_memory)

      assert length(todos) == 2
      titles = Enum.map(todos, & &1.title)
      assert "First" in titles
      assert "Second" in titles
    end

    test "get todo" do
      {:ok, created} = Run.execute(%CreateTodo{title: "Find me"}, mode: :in_memory)

      {:ok, found} = Run.execute(%GetTodo{id: created.id}, mode: :in_memory)

      assert found.id == created.id
      assert found.title == "Find me"
    end

    test "toggle todo" do
      {:ok, todo} = Run.execute(%CreateTodo{title: "Toggle me"}, mode: :in_memory)
      assert todo.completed == false

      {:ok, toggled} = Run.execute(%ToggleTodo{id: todo.id}, mode: :in_memory)
      assert toggled.completed == true

      {:ok, toggled_again} = Run.execute(%ToggleTodo{id: todo.id}, mode: :in_memory)
      assert toggled_again.completed == false
    end

    test "delete todo" do
      {:ok, todo} = Run.execute(%CreateTodo{title: "Delete me"}, mode: :in_memory)

      {:ok, deleted} = Run.execute(%DeleteTodo{id: todo.id}, mode: :in_memory)
      assert deleted.id == todo.id

      {:ok, todos} = Run.execute(%ListTodos{}, mode: :in_memory)
      assert todos == []
    end

    test "get stats" do
      {:ok, _} = Run.execute(%CreateTodo{title: "Active 1"}, mode: :in_memory)
      {:ok, todo2} = Run.execute(%CreateTodo{title: "To complete"}, mode: :in_memory)
      {:ok, _} = Run.execute(%ToggleTodo{id: todo2.id}, mode: :in_memory)

      {:ok, stats} = Run.execute(%GetStats{}, mode: :in_memory)

      assert stats.total == 2
      assert stats.active == 1
      assert stats.completed == 1
    end

    test "complete all" do
      {:ok, _} = Run.execute(%CreateTodo{title: "One"}, mode: :in_memory)
      {:ok, _} = Run.execute(%CreateTodo{title: "Two"}, mode: :in_memory)

      {:ok, result} = Run.execute(%CompleteAll{}, mode: :in_memory)
      assert result.updated == 2

      {:ok, stats} = Run.execute(%GetStats{}, mode: :in_memory)
      assert stats.completed == 2
      assert stats.active == 0
    end

    test "clear completed" do
      {:ok, todo1} = Run.execute(%CreateTodo{title: "Keep"}, mode: :in_memory)
      {:ok, todo2} = Run.execute(%CreateTodo{title: "Delete"}, mode: :in_memory)
      {:ok, _} = Run.execute(%ToggleTodo{id: todo2.id}, mode: :in_memory)

      {:ok, result} = Run.execute(%ClearCompleted{}, mode: :in_memory)
      assert result.deleted == 1

      {:ok, todos} = Run.execute(%ListTodos{}, mode: :in_memory)
      assert length(todos) == 1
      assert hd(todos).id == todo1.id
    end

    test "filter todos" do
      {:ok, _} = Run.execute(%CreateTodo{title: "Active"}, mode: :in_memory)
      {:ok, todo2} = Run.execute(%CreateTodo{title: "Completed"}, mode: :in_memory)
      {:ok, _} = Run.execute(%ToggleTodo{id: todo2.id}, mode: :in_memory)

      {:ok, active} = Run.execute(%ListTodos{filter: :active}, mode: :in_memory)
      assert length(active) == 1
      assert hd(active).title == "Active"

      {:ok, completed} = Run.execute(%ListTodos{filter: :completed}, mode: :in_memory)
      assert length(completed) == 1
      assert hd(completed).title == "Completed"

      {:ok, all} = Run.execute(%ListTodos{filter: :all}, mode: :in_memory)
      assert length(all) == 2
    end
  end
end
