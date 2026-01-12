defmodule TodosMcp.Run do
  @moduledoc """
  Runs domain operations through the Skuld effect handler stack.

  Sets up the layered handler chain:
  - Command effect → DomainHandler (business logic)
  - Reader effect → CommandContext (tenant isolation)
  - Query effect → DataAccess.Ecto (data access)
  - EctoPersist effect → Repo (persistence)
  - Throw effect → error handling

  ## Storage Modes

  - `:in_memory` (default) - Uses in-memory storage (no database required)
  - `:database` - Uses Ecto/Postgres for persistence

  Configure via application env or pass `:mode` option:

      # config/config.exs
      config :todos_mcp, :storage_mode, :in_memory

      # Or per-call
      Run.execute(operation, mode: :in_memory)

  ## Multi-tenancy

  Pass a context or tenant_id to scope operations:

      Run.execute(operation, context: %CommandContext{tenant_id: "tenant-123"})
      # Or shorthand:
      Run.execute(operation, tenant_id: "tenant-123")

  ## Example

      alias TodosMcp.Run
      alias TodosMcp.Commands.CreateTodo

      case Run.execute(%CreateTodo{title: "Buy milk"}, tenant_id: "my-tenant") do
        {:ok, todo} -> # success
        {:error, reason} -> # failure
      end
  """

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.{Command, Query, EctoPersist, Fresh, Throw, Reader}
  alias TodosMcp.{Repo, DomainHandler, DataAccess, CommandContext}
  alias TodosMcp.Effects.InMemoryPersist

  @doc """
  Execute a domain operation (command or query).

  ## Options

  - `:mode` - Storage mode: `:database` (default) or `:in_memory`
  - `:context` - CommandContext struct with tenant_id
  - `:tenant_id` - Shorthand for context (creates CommandContext)

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec execute(struct(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(operation, opts \\ []) do
    mode = Keyword.get(opts, :mode, storage_mode())
    context = get_context(opts)

    comp do
      result <- Command.execute(operation)
      result
    end
    |> Command.with_handler(&DomainHandler.handle/1)
    |> Reader.with_handler(context, tag: CommandContext)
    |> with_storage_handlers(mode)
    |> Fresh.with_uuid7_handler()
    |> Throw.with_handler()
    |> Comp.run()
    |> extract_result()
  end

  defp get_context(opts) do
    case Keyword.get(opts, :context) do
      %CommandContext{} = ctx -> ctx
      nil -> CommandContext.new(Keyword.get(opts, :tenant_id, "default"))
    end
  end

  @doc """
  Get the configured storage mode.

  Reads from application config `:todos_mcp, :storage_mode`.
  Defaults to `:in_memory`.
  """
  @spec storage_mode() :: :database | :in_memory
  def storage_mode do
    Application.get_env(:todos_mcp, :storage_mode, :in_memory)
  end

  # Install storage handlers based on mode
  defp with_storage_handlers(comp, :database) do
    comp
    |> Query.with_handler(%{DataAccess.Ecto => :direct})
    |> EctoPersist.with_handler(Repo)
  end

  defp with_storage_handlers(comp, :in_memory) do
    # Redirect DataAccess.Ecto requests to InMemoryImpl
    comp
    |> Query.with_handler(%{DataAccess.Ecto => {DataAccess.InMemoryImpl, :delegate}})
    |> InMemoryPersist.with_handler()
  end

  defp with_storage_handlers(_comp, mode) do
    raise ArgumentError, "Unknown storage mode: #{inspect(mode)}. Use :database or :in_memory"
  end

  defp extract_result({result, _env}) do
    case result do
      %Skuld.Comp.Throw{error: error} -> {:error, error}
      other -> other
    end
  end
end
