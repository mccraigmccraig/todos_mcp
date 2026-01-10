defmodule TodosMcp.DataAccess.InMemoryImpl do
  @moduledoc """
  In-memory implementation of DataAccess queries.

  Uses `TodosMcp.InMemoryStore` as the backing store. All functions
  return `{:ok, value}` or `{:error, reason}` result tuples.

  ## Usage with Query effect

      # Direct mode
      computation
      |> Query.with_handler(%{TodosMcp.DataAccess.InMemoryImpl => :direct})
      |> Comp.run!()

      # Delegation mode (redirect from Impl)
      computation
      |> Query.with_handler(%{TodosMcp.DataAccess.Impl => {TodosMcp.DataAccess.InMemoryImpl, :delegate}})
      |> Comp.run!()
  """

  alias TodosMcp.{InMemoryStore, Todo}

  @store InMemoryStore

  @doc """
  Delegate query from DataAccess.Impl to this module.

  Called by Query handler when resolver is `{InMemoryImpl, :delegate}`.
  """
  def delegate(_original_mod, name, params) do
    apply(__MODULE__, name, [params])
  end

  def get_todo(%{id: id}) do
    case @store.get(id) do
      nil -> {:error, {:not_found, Todo, id}}
      todo -> {:ok, todo}
    end
  end

  def list_todos(opts) do
    filter = Map.get(opts, :filter, :all)
    sort_by = Map.get(opts, :sort_by, :inserted_at)
    sort_order = Map.get(opts, :sort_order, :desc)

    todos =
      @store.all()
      |> apply_filter(filter)
      |> apply_sort(sort_by, sort_order)

    {:ok, todos}
  end

  def list_incomplete(%{}) do
    todos = @store.filter(fn todo -> !todo.completed end)
    {:ok, todos}
  end

  def list_completed(%{}) do
    todos = @store.filter(fn todo -> todo.completed end)
    {:ok, todos}
  end

  def search_todos(%{query: search_query, limit: limit}) do
    search_pattern = String.downcase(search_query)

    todos =
      @store.all()
      |> Enum.filter(fn todo ->
        title_match = todo.title && String.contains?(String.downcase(todo.title), search_pattern)

        desc_match =
          todo.description &&
            String.contains?(String.downcase(todo.description), search_pattern)

        title_match || desc_match
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:ok, todos}
  end

  def get_stats(%{}) do
    all = @store.all()
    total = length(all)
    completed = Enum.count(all, & &1.completed)
    active = total - completed

    {:ok, %{total: total, active: active, completed: completed}}
  end

  # Private helpers

  defp apply_filter(todos, :all), do: todos
  defp apply_filter(todos, :active), do: Enum.filter(todos, fn t -> !t.completed end)
  defp apply_filter(todos, :completed), do: Enum.filter(todos, fn t -> t.completed end)

  defp apply_sort(todos, field, :asc) do
    Enum.sort_by(todos, &Map.get(&1, field), &compare_asc/2)
  end

  defp apply_sort(todos, field, :desc) do
    Enum.sort_by(todos, &Map.get(&1, field), &compare_desc/2)
  end

  # Handle nil values and different types in sorting
  defp compare_asc(nil, _), do: true
  defp compare_asc(_, nil), do: false
  defp compare_asc(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp compare_asc(a, b), do: a <= b

  defp compare_desc(nil, _), do: false
  defp compare_desc(_, nil), do: true
  defp compare_desc(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :lt
  defp compare_desc(a, b), do: a >= b
end
