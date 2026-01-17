defmodule TodosMcp.CommandProcessorTest do
  use ExUnit.Case, async: false

  # Only run these tests in in_memory mode
  if Application.compile_env(:todos_mcp, :storage_mode, :in_memory) != :in_memory do
    @moduletag :skip
  end

  alias Skuld.AsyncRunner
  alias TodosMcp.CommandProcessor
  alias TodosMcp.InMemoryStore
  alias TodosMcp.Todos.Commands.CreateTodo
  alias TodosMcp.Todos.Commands.ToggleTodo
  alias TodosMcp.Todos.Commands.DeleteTodo
  alias TodosMcp.Todos.Queries.GetStats
  alias TodosMcp.Todos.Queries.ListTodos

  setup do
    InMemoryStore.clear()
    :ok
  end

  describe "build/1 with AsyncRunner" do
    test "starts and yields :ready" do
      processor = CommandProcessor.build(mode: :in_memory)

      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Clean up
      AsyncRunner.cancel(runner)
    end

    test "executes a command and yields result" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Send a create command
      {:yield, {:ok, todo}, _data} =
        AsyncRunner.resume_sync(runner, %CreateTodo{title: "Test todo"})

      assert todo.title == "Test todo"
      assert todo.id != nil
      assert todo.completed == false

      AsyncRunner.cancel(runner)
    end

    test "processes multiple commands in sequence" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Create first todo
      {:yield, {:ok, todo1}, _data} = AsyncRunner.resume_sync(runner, %CreateTodo{title: "First"})
      assert todo1.title == "First"

      # Create second todo
      {:yield, {:ok, todo2}, _data} =
        AsyncRunner.resume_sync(runner, %CreateTodo{title: "Second"})

      assert todo2.title == "Second"

      # List todos
      {:yield, {:ok, todos}, _data} = AsyncRunner.resume_sync(runner, %ListTodos{})
      assert length(todos) == 2

      # Get stats
      {:yield, {:ok, stats}, _data} = AsyncRunner.resume_sync(runner, %GetStats{})
      assert stats.total == 2
      assert stats.active == 2

      AsyncRunner.cancel(runner)
    end

    test "toggle and delete commands" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Create
      {:yield, {:ok, todo}, _data} =
        AsyncRunner.resume_sync(runner, %CreateTodo{title: "Toggle me"})

      assert todo.completed == false

      # Toggle
      {:yield, {:ok, toggled}, _data} = AsyncRunner.resume_sync(runner, %ToggleTodo{id: todo.id})
      assert toggled.completed == true

      # Delete
      {:yield, {:ok, deleted}, _data} = AsyncRunner.resume_sync(runner, %DeleteTodo{id: todo.id})
      assert deleted.id == todo.id

      # Verify deletion
      {:yield, {:ok, todos}, _data} = AsyncRunner.resume_sync(runner, %ListTodos{})
      assert todos == []

      AsyncRunner.cancel(runner)
    end

    test "stops gracefully with :stop command" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Send stop command
      {:result, :stopped} = AsyncRunner.resume_sync(runner, :stop)

      # Runner process should have exited
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end

    test "respects tenant isolation" do
      processor1 = CommandProcessor.build(mode: :in_memory, tenant_id: "tenant-1")
      processor2 = CommandProcessor.build(mode: :in_memory, tenant_id: "tenant-2")

      {:ok, runner1, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor1, tag: :cmd1)
      {:ok, runner2, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor2, tag: :cmd2)

      # Create in tenant 1
      {:yield, {:ok, _}, _data} =
        AsyncRunner.resume_sync(runner1, %CreateTodo{title: "Tenant 1 todo"})

      # Create in tenant 2
      {:yield, {:ok, _}, _data} =
        AsyncRunner.resume_sync(runner2, %CreateTodo{title: "Tenant 2 todo"})

      # List in tenant 1 - should only see tenant 1's todo
      {:yield, {:ok, todos1}, _data} = AsyncRunner.resume_sync(runner1, %ListTodos{})
      assert length(todos1) == 1
      assert hd(todos1).title == "Tenant 1 todo"

      # List in tenant 2 - should only see tenant 2's todo
      {:yield, {:ok, todos2}, _data} = AsyncRunner.resume_sync(runner2, %ListTodos{})
      assert length(todos2) == 1
      assert hd(todos2).title == "Tenant 2 todo"

      AsyncRunner.cancel(runner1)
      AsyncRunner.cancel(runner2)
    end

    test "handles errors gracefully" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Try to get a non-existent todo
      {:yield, {:error, :not_found}, _data} =
        AsyncRunner.resume_sync(runner, %TodosMcp.Todos.Queries.GetTodo{id: "nonexistent"})

      # Processor should still be alive and ready for next command
      {:yield, {:ok, todo}, _data} =
        AsyncRunner.resume_sync(runner, %CreateTodo{title: "After error"})

      assert todo.title == "After error"

      AsyncRunner.cancel(runner)
    end
  end

  describe "async usage pattern" do
    test "can use async resume for commands" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, {:yield, :ready, _data}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Use async resume
      :ok = AsyncRunner.resume(runner, %CreateTodo{title: "Async created"})

      # Receive the result via message (4-element tuple with data)
      assert_receive {:cmd, :yield, {:ok, todo}, _data}
      assert todo.title == "Async created"

      AsyncRunner.cancel(runner)
    end
  end
end
