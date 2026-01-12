defmodule TodosMcp.Todos.Repository.Ecto do
  @moduledoc """
  Ecto/Postgres implementation of repository operations.

  All functions return `{:ok, value}` | `{:error, reason}` result tuples.
  Used by the Query effect handler in production mode.
  """

  import Ecto.Query
  alias TodosMcp.Repo
  alias TodosMcp.Todos.Todo

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
