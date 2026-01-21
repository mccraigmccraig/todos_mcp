defmodule TodosMcp.CommandProcessor do
  @moduledoc """
  A long-lived command processor that can be used with AsyncComputation.

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

  ## Usage with AsyncComputation

      # Start the processor
      processor = CommandProcessor.build(tenant_id: "tenant-123")
      {:ok, runner, {:yield, :ready, _data}} = AsyncComputation.start_sync(processor, tag: :cmd)

      # Execute commands synchronously (data contains any scoped effect decorations)
      {:yield, {:ok, todo}, _data} = AsyncComputation.resume_sync(runner, %CreateTodo{title: "Buy milk"})
      {:yield, {:ok, stats}, _data} = AsyncComputation.resume_sync(runner, %GetStats{})

      # Cancel when done (or let it be garbage collected)
      AsyncComputation.cancel(runner)

  ## Stopping the Processor

  Send the `:stop` atom to gracefully stop the processor:

      {:result, :stopped} = AsyncComputation.resume_sync(runner, :stop)
  """

  use Skuld.Syntax

  require Logger

  alias Skuld.Effects.ChangesetPersist
  alias Skuld.Effects.Command
  alias Skuld.Effects.Fresh
  alias Skuld.Effects.Query
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias TodosMcp.CommandContext
  alias TodosMcp.Effects.InMemoryPersist
  alias TodosMcp.Repo
  alias TodosMcp.Todos.Handlers
  alias TodosMcp.Todos.Repository

  @doc """
  Build a command processor computation.

  ## Options

  - `:mode` - Storage mode: `:database` or `:in_memory` (default from config)
  - `:context` - CommandContext struct with tenant_id
  - `:tenant_id` - Shorthand for context (creates CommandContext)

  Returns a computation ready to be started with `AsyncComputation.start_sync/2`.
  """
  @spec build(keyword()) :: Skuld.Comp.Types.computation()
  def build(opts \\ []) do
    mode = Keyword.get(opts, :mode, storage_mode())
    context = get_context(opts)

    command_loop()
    |> State.with_handler(%{})
    |> Command.with_handler(&Handlers.handle/1)
    |> Reader.with_handler(context, tag: CommandContext)
    |> with_storage_handlers(mode)
    |> Fresh.with_uuid7_handler()
  end

  # The main command processing loop
  # Flow: yield(:ready) → resume(cmd1) → yield(result1) → resume(cmd2) → yield(result2) → ...
  defcompp command_loop do
    # Yield :ready to signal we're waiting for a command
    cmd <- Skuld.Effects.Yield.yield(:ready)
    process_command_loop(cmd)
  end

  defcompp(process_command_loop(:stop), do: :stopped)

  defcompp process_command_loop(operation) do
    # Execute the command
    result <- Command.execute(operation)

    # Update command counts
    counts <- State.get()
    cmd_module = operation.__struct__
    new_counts = Map.update(counts, cmd_module, 1, &(&1 + 1))
    _ <- State.put(new_counts)

    # Log the counts
    _ <- log_counts(new_counts)

    # Yield the result - the resume value is the next command
    next_cmd <- Skuld.Effects.Yield.yield(result)
    process_command_loop(next_cmd)
  end

  defcompp log_counts(counts) do
    formatted =
      counts
      |> Enum.map(fn {mod, count} ->
        short_name = mod |> Module.split() |> List.last()
        "#{short_name}: #{count}"
      end)
      |> Enum.join(", ")

    _ = Logger.info("[CommandProcessor] Command counts: #{formatted}")
    :ok
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
