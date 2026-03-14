defmodule TodosMcp.Todos.Repository do
  @moduledoc """
  Repository port contract for todos.

  Defines typed port operations for data access, generating caller functions,
  bang variants, behaviour callbacks, key helpers, and introspection.

  ## Storage Modes

  The implementation module is selected via the Port handler registry:
  - `:database` → `Repository.Ecto` (Ecto/Postgres)
  - `:in_memory` → `Repository.InMemory` (Agent-based)

  ## API Variants

  - Plain functions (`get_todo/2`) return result tuples `{:ok, value}` or
    `{:error, reason}` for explicit error handling
  - Bang functions (`get_todo!/2`) unwrap success or dispatch `Throw` on error

  ## Example

      comp do
        # Throws if not found
        todo <- Repository.get_todo!(tenant_id, id)
        # ... work with todo
      end

      comp do
        # Returns result tuple
        result <- Repository.get_todo(tenant_id, id)
        case result do
          {:ok, todo} -> ...
          {:error, _} -> ...
        end
      end

  ## Implementation

      defmodule TodosMcp.Todos.Repository.Ecto do
        @behaviour TodosMcp.Todos.Repository

        @impl true
        def get_todo(tenant_id, id), do: ...
      end

  ## Handler Installation

      my_comp
      |> Port.with_handler(%{Repository => Repository.Ecto})
      |> Comp.run!()
  """

  use Skuld.Effects.Port.Contract

  alias TodosMcp.Todos.Todo

  @doc """
  Fetch a single todo by tenant and id.

  Returns `{:ok, todo}` if found, or `{:error, {:not_found, Todo, id}}` if not.
  """
  defport(
    get_todo(tenant_id :: String.t(), id :: String.t()) ::
      {:ok, Todo.t()} | {:error, term()}
  )

  @doc """
  List todos for a tenant with optional filtering and sorting.

  ## Opts

    * `:filter` - `:all` | `:active` | `:completed` (default `:all`)
    * `:sort_by` - `:inserted_at` | `:title` | `:priority` (default `:inserted_at`)
    * `:sort_order` - `:asc` | `:desc` (default `:desc`)
  """
  defport(
    list_todos(tenant_id :: String.t(), opts :: map()) ::
      {:ok, [Todo.t()]} | {:error, term()}
  )

  @doc """
  List all incomplete (not completed) todos for a tenant.
  """
  defport(
    list_incomplete(tenant_id :: String.t()) ::
      {:ok, [Todo.t()]} | {:error, term()}
  )

  @doc """
  List all completed todos for a tenant.
  """
  defport(
    list_completed(tenant_id :: String.t()) ::
      {:ok, [Todo.t()]} | {:error, term()}
  )

  @doc """
  Search todos by title/description for a tenant.

  Returns up to `limit` matching todos, ordered by relevance.
  """
  defport(
    search_todos(tenant_id :: String.t(), query :: String.t(), limit :: integer()) ::
      {:ok, [Todo.t()]} | {:error, term()}
  )

  @doc """
  Get aggregate statistics for a tenant's todos.

  Returns a map with `:total`, `:active`, and `:completed` counts.
  """
  defport(
    get_stats(tenant_id :: String.t()) ::
      {:ok, map()} | {:error, term()}
  )
end
