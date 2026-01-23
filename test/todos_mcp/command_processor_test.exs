defmodule TodosMcp.CommandProcessorTest do
  use ExUnit.Case, async: false

  # Only run these tests in in_memory mode
  if Application.compile_env(:todos_mcp, :storage_mode, :in_memory) != :in_memory do
    @moduletag :skip
  end

  alias Skuld.AsyncComputation
  alias Skuld.Comp.Suspend
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

  describe "build/1 with AsyncComputation" do
    test "starts and yields :ready" do
      processor = CommandProcessor.build(mode: :in_memory)

      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Clean up
      AsyncComputation.cancel(runner)
    end

    test "executes a command and yields result" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Send a create command
      %Suspend{value: {:ok, todo}} =
        AsyncComputation.resume_sync(runner, %CreateTodo{title: "Test todo"})

      assert todo.title == "Test todo"
      assert todo.id != nil
      assert todo.completed == false

      AsyncComputation.cancel(runner)
    end

    test "processes multiple commands in sequence" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Create first todo
      %Suspend{value: {:ok, todo1}} =
        AsyncComputation.resume_sync(runner, %CreateTodo{title: "First"})

      assert todo1.title == "First"

      # Create second todo
      %Suspend{value: {:ok, todo2}} =
        AsyncComputation.resume_sync(runner, %CreateTodo{title: "Second"})

      assert todo2.title == "Second"

      # List todos
      %Suspend{value: {:ok, todos}} = AsyncComputation.resume_sync(runner, %ListTodos{})
      assert length(todos) == 2

      # Get stats
      %Suspend{value: {:ok, stats}} = AsyncComputation.resume_sync(runner, %GetStats{})
      assert stats.total == 2
      assert stats.active == 2

      AsyncComputation.cancel(runner)
    end

    test "toggle and delete commands" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Create
      %Suspend{value: {:ok, todo}} =
        AsyncComputation.resume_sync(runner, %CreateTodo{title: "Toggle me"})

      assert todo.completed == false

      # Toggle
      %Suspend{value: {:ok, toggled}} =
        AsyncComputation.resume_sync(runner, %ToggleTodo{id: todo.id})

      assert toggled.completed == true

      # Delete
      %Suspend{value: {:ok, deleted}} =
        AsyncComputation.resume_sync(runner, %DeleteTodo{id: todo.id})

      assert deleted.id == todo.id

      # Verify deletion
      %Suspend{value: {:ok, todos}} = AsyncComputation.resume_sync(runner, %ListTodos{})
      assert todos == []

      AsyncComputation.cancel(runner)
    end

    test "stops gracefully with :stop command" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Send stop command - returns plain value (not a Suspend)
      :stopped = AsyncComputation.resume_sync(runner, :stop)

      # Runner process should have exited
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end

    test "respects tenant isolation" do
      processor1 = CommandProcessor.build(mode: :in_memory, tenant_id: "tenant-1")
      processor2 = CommandProcessor.build(mode: :in_memory, tenant_id: "tenant-2")

      {:ok, runner1, %Suspend{value: :ready}} =
        AsyncComputation.start_sync(processor1, tag: :cmd1)

      {:ok, runner2, %Suspend{value: :ready}} =
        AsyncComputation.start_sync(processor2, tag: :cmd2)

      # Create in tenant 1
      %Suspend{value: {:ok, _}} =
        AsyncComputation.resume_sync(runner1, %CreateTodo{title: "Tenant 1 todo"})

      # Create in tenant 2
      %Suspend{value: {:ok, _}} =
        AsyncComputation.resume_sync(runner2, %CreateTodo{title: "Tenant 2 todo"})

      # List in tenant 1 - should only see tenant 1's todo
      %Suspend{value: {:ok, todos1}} = AsyncComputation.resume_sync(runner1, %ListTodos{})
      assert length(todos1) == 1
      assert hd(todos1).title == "Tenant 1 todo"

      # List in tenant 2 - should only see tenant 2's todo
      %Suspend{value: {:ok, todos2}} = AsyncComputation.resume_sync(runner2, %ListTodos{})
      assert length(todos2) == 1
      assert hd(todos2).title == "Tenant 2 todo"

      AsyncComputation.cancel(runner1)
      AsyncComputation.cancel(runner2)
    end

    test "handles errors gracefully" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Try to get a non-existent todo
      %Suspend{value: {:error, :not_found}} =
        AsyncComputation.resume_sync(runner, %TodosMcp.Todos.Queries.GetTodo{id: "nonexistent"})

      # Processor should still be alive and ready for next command
      %Suspend{value: {:ok, todo}} =
        AsyncComputation.resume_sync(runner, %CreateTodo{title: "After error"})

      assert todo.title == "After error"

      AsyncComputation.cancel(runner)
    end
  end

  describe "async usage pattern" do
    test "can use async resume for commands" do
      processor = CommandProcessor.build(mode: :in_memory)
      {:ok, runner, %Suspend{value: :ready}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Use async resume
      :ok = AsyncComputation.resume(runner, %CreateTodo{title: "Async created"})

      # Receive the result via message (new uniform format)
      assert_receive {AsyncComputation, :cmd, %Suspend{value: {:ok, todo}}}
      assert todo.title == "Async created"

      AsyncComputation.cancel(runner)
    end
  end
end
