defmodule TodosMcp.Todos.QueryPort.Ecto do
  @moduledoc """
  Ecto/Postgres implementation of the QueryPort port contract.

  All functions return `{:ok, value}` | `{:error, reason}` result tuples.
  Used by the Port effect handler in production mode.
  """

  @behaviour TodosMcp.Todos.QueryPort

  import Ecto.Query
  alias TodosMcp.Repo
  alias TodosMcp.Todos.Todo

  # Tenant-scoped base query - ensures all queries are filtered by tenant
  defp scoped(tenant_id), do: from(t in Todo, where: t.tenant_id == ^tenant_id)

  @impl true
  def get_todo(tenant_id, id) do
    case scoped(tenant_id) |> where([t], t.id == ^id) |> Repo.one() do
      nil -> {:error, {:not_found, Todo, id}}
      todo -> {:ok, todo}
    end
  end

  @impl true
  def list_todos(tenant_id, opts) do
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

  @impl true
  def list_incomplete(tenant_id) do
    todos =
      scoped(tenant_id)
      |> where([t], t.completed == false)
      |> Repo.all()

    {:ok, todos}
  end

  @impl true
  def list_completed(tenant_id) do
    todos =
      scoped(tenant_id)
      |> where([t], t.completed == true)
      |> Repo.all()

    {:ok, todos}
  end

  @impl true
  def search_todos(tenant_id, search_query, limit) do
    search_pattern = "%#{search_query}%"

    todos =
      scoped(tenant_id)
      |> where([t], ilike(t.title, ^search_pattern) or ilike(t.description, ^search_pattern))
      |> order_by([t], desc: t.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    {:ok, todos}
  end

  @impl true
  def get_stats(tenant_id) do
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
