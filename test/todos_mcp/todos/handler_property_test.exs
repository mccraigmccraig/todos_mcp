defmodule TodosMcp.Todos.HandlerPropertyTest do
  @moduledoc """
  Property-based tests for Todos.Handler using stream_data.

  These tests run with pure in-memory handlers (no database), enabling
  thousands of iterations in seconds. This demonstrates the power of
  algebraic effects for testing - the exact same domain logic runs
  with different effect interpreters.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  # Skip these tests in database mode - they require InMemoryStore
  if Application.compile_env(:todos_mcp, :storage_mode, :in_memory) == :database do
    @moduletag :skip
  end

  alias TodosMcp.{Run, InMemoryStore}
  alias TodosMcp.Generators

  alias TodosMcp.Todos.Commands.{
    UpdateTodo,
    ToggleTodo,
    CompleteAll,
    ClearCompleted
  }

  alias TodosMcp.Todos.Queries.{ListTodos, GetStats}

  @test_tenant "property-test-tenant"

  # Helper to run an operation with a fresh in-memory store seeded with todos
  defp run_with_todos(operation, todos) do
    # Clear and seed the store
    InMemoryStore.clear()

    for todo <- todos do
      InMemoryStore.insert(todo)
    end

    Run.execute(operation, mode: :in_memory, tenant_id: @test_tenant)
  end

  # Helper to run CreateTodo and get the created todo
  defp create_and_get(cmd) do
    InMemoryStore.clear()
    Run.execute(cmd, mode: :in_memory, tenant_id: @test_tenant)
  end

  # Comparison helpers for sorting (handles DateTime properly)
  defp compare_asc(nil, nil), do: true
  defp compare_asc(nil, _), do: true
  defp compare_asc(_, nil), do: false
  defp compare_asc(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp compare_asc(a, b), do: a <= b

  defp compare_desc(nil, nil), do: true
  defp compare_desc(nil, _), do: false
  defp compare_desc(_, nil), do: true
  defp compare_desc(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :lt
  defp compare_desc(a, b), do: a >= b

  # Check if a list is sorted by a given field in the given order
  defp is_sorted?(list, _field, _order) when length(list) < 2, do: true

  defp is_sorted?(list, field, order) do
    comparator = if order == :asc, do: &compare_asc/2, else: &compare_desc/2

    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] ->
      val_a = Map.get(a, field)
      val_b = Map.get(b, field)
      comparator.(val_a, val_b)
    end)
  end

  #############################################################################
  ## Command Properties
  #############################################################################

  describe "CreateTodo properties" do
    property "always succeeds with valid input and returns matching todo" do
      check all(cmd <- Generators.create_todo(), max_runs: 100) do
        {:ok, todo} = create_and_get(cmd)

        assert todo.title == cmd.title
        assert todo.description == cmd.description
        assert todo.priority == cmd.priority
        assert todo.completed == false
        assert todo.tenant_id == @test_tenant
        assert is_binary(todo.id) and String.length(todo.id) == 36
      end
    end
  end

  describe "ToggleTodo properties" do
    property "is self-inverse (toggle twice = original completed state)" do
      check all(cmd <- Generators.create_todo(), max_runs: 100) do
        # Create a todo
        {:ok, original} = create_and_get(cmd)
        original_completed = original.completed

        # Toggle once
        {:ok, toggled} =
          Run.execute(%ToggleTodo{id: original.id}, mode: :in_memory, tenant_id: @test_tenant)

        assert toggled.completed == not original_completed

        # Toggle again
        {:ok, restored} =
          Run.execute(%ToggleTodo{id: original.id}, mode: :in_memory, tenant_id: @test_tenant)

        assert restored.completed == original_completed
      end
    end
  end

  describe "UpdateTodo properties" do
    property "preserves fields that are not updated (nil fields)" do
      check all(
              create_cmd <- Generators.create_todo(),
              new_title <- Generators.todo_title(),
              max_runs: 100
            ) do
        # Create a todo
        {:ok, original} = create_and_get(create_cmd)

        # Update only the title (other fields are nil)
        update_cmd = %UpdateTodo{id: original.id, title: new_title}
        {:ok, updated} = Run.execute(update_cmd, mode: :in_memory, tenant_id: @test_tenant)

        # Title changed
        assert updated.title == new_title

        # Other fields preserved
        assert updated.description == original.description
        assert updated.priority == original.priority
        assert updated.completed == original.completed
        assert updated.id == original.id
      end
    end

    property "applies all non-nil fields" do
      check all(
              create_cmd <- Generators.create_todo(),
              new_title <- Generators.todo_title(),
              new_desc <- Generators.todo_description(),
              new_priority <- Generators.priority(),
              max_runs: 100
            ) do
        {:ok, original} = create_and_get(create_cmd)

        update_cmd = %UpdateTodo{
          id: original.id,
          title: new_title,
          description: new_desc,
          priority: new_priority
        }

        {:ok, updated} = Run.execute(update_cmd, mode: :in_memory, tenant_id: @test_tenant)

        assert updated.title == new_title
        assert updated.description == new_desc
        assert updated.priority == new_priority
      end
    end
  end

  describe "CompleteAll properties" do
    property "only affects incomplete todos" do
      check all(
              todos <- Generators.todos(min_length: 0, max_length: 20, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        # Ensure all todos have correct tenant
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})
        incomplete_count = Enum.count(todos, &(not &1.completed))

        {:ok, result} = run_with_todos(%CompleteAll{}, todos)

        assert result.updated == incomplete_count
      end
    end

    property "results in all todos being completed" do
      check all(
              todos <- Generators.todos(min_length: 1, max_length: 10, tenant_id: @test_tenant),
              max_runs: 50
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})

        {:ok, _} = run_with_todos(%CompleteAll{}, todos)

        # Query all todos - they should all be completed now
        {:ok, all_todos} =
          Run.execute(%ListTodos{filter: :all}, mode: :in_memory, tenant_id: @test_tenant)

        assert Enum.all?(all_todos, & &1.completed)
      end
    end
  end

  describe "ClearCompleted properties" do
    property "only removes completed todos" do
      check all(
              todos <- Generators.todos(min_length: 0, max_length: 20, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})
        completed_count = Enum.count(todos, & &1.completed)

        {:ok, result} = run_with_todos(%ClearCompleted{}, todos)

        assert result.deleted == completed_count
      end
    end

    property "leaves only incomplete todos" do
      check all(
              todos <- Generators.todos(min_length: 1, max_length: 10, tenant_id: @test_tenant),
              max_runs: 50
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})
        original_incomplete = Enum.filter(todos, &(not &1.completed))

        {:ok, _} = run_with_todos(%ClearCompleted{}, todos)

        # Query remaining todos
        {:ok, remaining} =
          Run.execute(%ListTodos{filter: :all}, mode: :in_memory, tenant_id: @test_tenant)

        # Only incomplete todos should remain
        assert length(remaining) == length(original_incomplete)
        assert Enum.all?(remaining, &(not &1.completed))
      end
    end
  end

  #############################################################################
  ## Query Properties
  #############################################################################

  describe "ListTodos properties" do
    property "filter :all returns all todos" do
      check all(
              todos <- Generators.todos(max_length: 20, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})

        {:ok, results} = run_with_todos(%ListTodos{filter: :all}, todos)

        assert length(results) == length(todos)
      end
    end

    property "filter :active returns only incomplete todos" do
      check all(
              todos <- Generators.todos(max_length: 20, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})
        expected_count = Enum.count(todos, &(not &1.completed))

        {:ok, results} = run_with_todos(%ListTodos{filter: :active}, todos)

        assert length(results) == expected_count
        assert Enum.all?(results, &(not &1.completed))
      end
    end

    property "filter :completed returns only completed todos" do
      check all(
              todos <- Generators.todos(max_length: 20, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})
        expected_count = Enum.count(todos, & &1.completed)

        {:ok, results} = run_with_todos(%ListTodos{filter: :completed}, todos)

        assert length(results) == expected_count
        assert Enum.all?(results, & &1.completed)
      end
    end

    property "results are sorted correctly" do
      check all(
              todos <- Generators.todos(min_length: 2, max_length: 15, tenant_id: @test_tenant),
              sort_by <- Generators.sort_by(),
              sort_order <- Generators.sort_order(),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})

        query = %ListTodos{filter: :all, sort_by: sort_by, sort_order: sort_order}
        {:ok, results} = run_with_todos(query, todos)

        # Verify sorting property: each adjacent pair respects the sort order
        # (We check the property directly rather than re-sorting, because Enum.sort_by
        # is not stable and may reorder equal elements differently)
        assert is_sorted?(results, sort_by, sort_order)
      end
    end
  end

  describe "GetStats properties" do
    property "counts are accurate" do
      check all(
              todos <- Generators.todos(max_length: 30, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})
        expected_total = length(todos)
        expected_completed = Enum.count(todos, & &1.completed)
        expected_active = expected_total - expected_completed

        {:ok, stats} = run_with_todos(%GetStats{}, todos)

        assert stats.total == expected_total
        assert stats.completed == expected_completed
        assert stats.active == expected_active
      end
    end

    property "total = active + completed" do
      check all(
              todos <- Generators.todos(max_length: 50, tenant_id: @test_tenant),
              max_runs: 100
            ) do
        todos = Enum.map(todos, &%{&1 | tenant_id: @test_tenant})

        {:ok, stats} = run_with_todos(%GetStats{}, todos)

        assert stats.total == stats.active + stats.completed
      end
    end
  end
end
