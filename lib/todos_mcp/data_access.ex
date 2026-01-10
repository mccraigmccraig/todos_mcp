defmodule TodosMcp.DataAccess do
  @moduledoc """
  Data access layer for todos.

  Public functions return `Skuld.Effects.Query` computations, keeping the
  Query effect abstraction while providing a clean API.

  ## Storage Modes

  The implementation module is selected based on the configured storage mode:
  - `:database` → `DataAccess.Impl` (Ecto/Postgres)
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

  # All requests go to Impl - the Query handler maps to the actual implementation
  # based on storage mode (database -> Impl direct, in_memory -> InMemoryImpl)

  # Get a single todo by ID (returns {:ok, todo} or {:error, :not_found})
  def get_todo(tenant_id, id),
    do: Query.request(__MODULE__.Impl, :get_todo, %{tenant_id: tenant_id, id: id})

  # Get a single todo by ID (throws if not found)
  def get_todo!(tenant_id, id),
    do: Query.request!(__MODULE__.Impl, :get_todo, %{tenant_id: tenant_id, id: id})

  # List todos with optional filtering and sorting
  def list_todos(tenant_id, opts \\ %{}) do
    Query.request!(__MODULE__.Impl, :list_todos, Map.put(opts, :tenant_id, tenant_id))
  end

  # List only incomplete todos for a tenant
  def list_incomplete(tenant_id),
    do: Query.request!(__MODULE__.Impl, :list_incomplete, %{tenant_id: tenant_id})

  # List only completed todos for a tenant
  def list_completed(tenant_id),
    do: Query.request!(__MODULE__.Impl, :list_completed, %{tenant_id: tenant_id})

  # Search todos by title/description
  def search_todos(tenant_id, query, limit \\ 20) do
    Query.request!(__MODULE__.Impl, :search_todos, %{
      tenant_id: tenant_id,
      query: query,
      limit: limit
    })
  end

  # Get statistics (total, active, completed counts) for a tenant
  def get_stats(tenant_id),
    do: Query.request!(__MODULE__.Impl, :get_stats, %{tenant_id: tenant_id})

  # Implementation module with actual Ecto queries.
  # All functions return {:ok, value} | {:error, reason} result tuples.
  defmodule Impl do
    @moduledoc false

    import Ecto.Query
    alias TodosMcp.{Repo, Todo}

    # Tenant-scoped base query - ensures all queries are filtered by tenant
    defp scoped(tenant_id), do: from(t in Todo, where: t.tenant_id == ^tenant_id)

    def get_todo(%{tenant_id: tenant_id, id: id}) do
      case scoped(tenant_id) |> where([t], t.id == ^id) |> Repo.one() do
        nil -> {:error, {:not_found, Todo, id}}
        todo -> {:ok, todo}
      end
    end

    def list_todos(opts) do
      tenant_id = Map.fetch!(opts, :tenant_id)
      filter = Map.get(opts, :filter, :all)
      sort_by = Map.get(opts, :sort_by, :inserted_at)
      sort_order = Map.get(opts, :sort_order, :desc)

      todos =
        scoped(tenant_id)
        |> apply_filter(filter)
        |> apply_sort(sort_by, sort_order)
        |> Repo.all()

      {:ok, todos}
    end

    def list_incomplete(%{tenant_id: tenant_id}) do
      todos =
        scoped(tenant_id)
        |> where([t], t.completed == false)
        |> Repo.all()

      {:ok, todos}
    end

    def list_completed(%{tenant_id: tenant_id}) do
      todos =
        scoped(tenant_id)
        |> where([t], t.completed == true)
        |> Repo.all()

      {:ok, todos}
    end

    def search_todos(%{tenant_id: tenant_id, query: search_query, limit: limit}) do
      search_pattern = "%#{search_query}%"

      todos =
        scoped(tenant_id)
        |> where([t], ilike(t.title, ^search_pattern) or ilike(t.description, ^search_pattern))
        |> order_by([t], desc: t.inserted_at)
        |> limit(^limit)
        |> Repo.all()

      {:ok, todos}
    end

    def get_stats(%{tenant_id: tenant_id}) do
      base = scoped(tenant_id)
      total = Repo.aggregate(base, :count)
      completed = Repo.aggregate(where(base, [t], t.completed == true), :count)
      active = total - completed

      {:ok, %{total: total, active: active, completed: completed}}
    end

    # Private helpers

    defp apply_filter(query, :all), do: query
    defp apply_filter(query, :active), do: where(query, [t], t.completed == false)
    defp apply_filter(query, :completed), do: where(query, [t], t.completed == true)

    defp apply_sort(query, field, :asc), do: order_by(query, [t], asc: ^field)
    defp apply_sort(query, field, :desc), do: order_by(query, [t], desc: ^field)
  end
end
