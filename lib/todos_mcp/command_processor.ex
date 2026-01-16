defmodule TodosMcp.CommandProcessor do
  @moduledoc """
  A long-lived command processor that can be used with AsyncRunner.

  Instead of creating a new computation for each command (like `Run.execute/2`),
  CommandProcessor builds a computation that:

  1. Sets up the effect handler stack once
  2. Yields `:ready` to signal it's waiting for a command
  3. Receives a command via resume
  4. Executes it through the domain handlers
  5. Yields the result
  6. Loops back to step 2

  This keeps the handler stack alive across multiple commands, which can be
  useful for connection pooling, caching, or maintaining state.

  ## Usage with AsyncRunner

      # Start the processor
      processor = CommandProcessor.build(tenant_id: "tenant-123")
      {:ok, runner, {:yield, :ready}} = AsyncRunner.start_sync(processor, tag: :cmd)

      # Execute commands synchronously
      {:yield, {:ok, todo}} = AsyncRunner.resume_sync(runner, %CreateTodo{title: "Buy milk"})
      {:yield, {:ok, stats}} = AsyncRunner.resume_sync(runner, %GetStats{})

      # Cancel when done (or let it be garbage collected)
      AsyncRunner.cancel(runner)

  ## Stopping the Processor

  Send the `:stop` atom to gracefully stop the processor:

      {:result, :stopped} = AsyncRunner.resume_sync(runner, :stop)
  """

  use Skuld.Syntax

  alias Skuld.Effects.Command
  alias Skuld.Effects.ChangesetPersist
  alias Skuld.Effects.Fresh
  alias Skuld.Effects.Query
  alias Skuld.Effects.Reader
  alias TodosMcp.CommandContext
  alias TodosMcp.Repo
  alias TodosMcp.Todos.Handlers
  alias TodosMcp.Todos.Repository
  alias TodosMcp.Effects.InMemoryPersist

  @doc """
  Build a command processor computation.

  ## Options

  - `:mode` - Storage mode: `:database` or `:in_memory` (default from config)
  - `:context` - CommandContext struct with tenant_id
  - `:tenant_id` - Shorthand for context (creates CommandContext)

  Returns a computation ready to be started with `AsyncRunner.start_sync/2`.
  """
  @spec build(keyword()) :: Skuld.Comp.Types.computation()
  def build(opts \\ []) do
    mode = Keyword.get(opts, :mode, storage_mode())
    context = get_context(opts)

    command_loop()
    |> Command.with_handler(&Handlers.handle/1)
    |> Reader.with_handler(context, tag: CommandContext)
    |> with_storage_handlers(mode)
    |> Fresh.with_uuid7_handler()
  end

  # The main command processing loop
  # Flow: yield(:ready) → resume(cmd1) → yield(result1) → resume(cmd2) → yield(result2) → ...
  defp command_loop do
    comp do
      # Yield :ready to signal we're waiting for a command
      cmd <- Skuld.Effects.Yield.yield(:ready)
      process_command_loop(cmd)
    end
  end

  defp process_command_loop(:stop), do: Skuld.Comp.return(:stopped)

  defp process_command_loop(operation) do
    comp do
      result <- Command.execute(operation)
      # Yield the result - the resume value is the next command
      next_cmd <- Skuld.Effects.Yield.yield(result)
      process_command_loop(next_cmd)
    end
  end

  defp get_context(opts) do
    case Keyword.get(opts, :context) do
      %CommandContext{} = ctx -> ctx
      nil -> CommandContext.new(Keyword.get(opts, :tenant_id, "default"))
    end
  end

  defp storage_mode do
    Application.get_env(:todos_mcp, :storage_mode, :in_memory)
  end

  defp with_storage_handlers(comp, :database) do
    comp
    |> Query.with_handler(%{Repository.Ecto => :direct})
    |> ChangesetPersist.Ecto.with_handler(Repo)
  end

  defp with_storage_handlers(comp, :in_memory) do
    comp
    |> Query.with_handler(%{Repository.Ecto => {Repository.InMemory, :delegate}})
    |> InMemoryPersist.with_handler()
  end

  defp with_storage_handlers(_comp, mode) do
    raise ArgumentError, "Unknown storage mode: #{inspect(mode)}. Use :database or :in_memory"
  end
end
