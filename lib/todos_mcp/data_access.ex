defmodule TodosMcp.DataAccess do
  @moduledoc """
  Data access layer for todos.

  Public functions return `Skuld.Effects.Query` computations, keeping the
  Query effect abstraction while providing a clean API.

  ## Storage Modes

  The implementation module is selected based on the configured storage mode:
  - `:database` → `DataAccess.Ecto` (Ecto/Postgres)
  - `:in_memory` → `DataAccess.InMemoryImpl` (Agent-based)

  ## API Variants

  - Plain functions (`get_todo/1`) return result tuples `{:ok, value}` or
    `{:error, reason}` for explicit error handling
  - Bang functions (`get_todo!/1`) unwrap success or dispatch `Throw` on error

  ## Example

      comp do
        # Throws if not found
        todo <- DataAccess.get_todo!(id)
        # ... work with todo
      end

      comp do
        # Returns result tuple
        result <- DataAccess.get_todo(id)
        case result do
          {:ok, todo} -> ...
          {:error, _} -> ...
        end
      end
  """

  alias Skuld.Effects.Query

  # All requests go to Ecto - the Query handler maps to the actual implementation
  # based on storage mode (database -> Ecto direct, in_memory -> InMemoryImpl)

  # Get a single todo by ID (returns {:ok, todo} or {:error, :not_found})
  def get_todo(tenant_id, id),
    do: Query.request(__MODULE__.Ecto, :get_todo, %{tenant_id: tenant_id, id: id})

  # Get a single todo by ID (throws if not found)
  def get_todo!(tenant_id, id),
    do: Query.request!(__MODULE__.Ecto, :get_todo, %{tenant_id: tenant_id, id: id})

  # List todos with optional filtering and sorting
  def list_todos(tenant_id, opts \\ %{}) do
    Query.request!(__MODULE__.Ecto, :list_todos, Map.put(opts, :tenant_id, tenant_id))
  end

  # List only incomplete todos for a tenant
  def list_incomplete(tenant_id),
    do: Query.request!(__MODULE__.Ecto, :list_incomplete, %{tenant_id: tenant_id})

  # List only completed todos for a tenant
  def list_completed(tenant_id),
    do: Query.request!(__MODULE__.Ecto, :list_completed, %{tenant_id: tenant_id})

  # Search todos by title/description
  def search_todos(tenant_id, query, limit \\ 20) do
    Query.request!(__MODULE__.Ecto, :search_todos, %{
      tenant_id: tenant_id,
      query: query,
      limit: limit
    })
  end

  # Get statistics (total, active, completed counts) for a tenant
  def get_stats(tenant_id),
    do: Query.request!(__MODULE__.Ecto, :get_stats, %{tenant_id: tenant_id})
end
