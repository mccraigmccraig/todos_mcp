defmodule TodosMcp.InMemoryStore do
  @moduledoc """
  In-memory storage for todos using Agent.

  Provides a simple key-value store keyed by todo ID, with support for
  the operations needed by both persistence and query handlers.

  ## Usage

  Start the store (typically in your application supervisor):

      TodosMcp.InMemoryStore.start_link([])

  Or use in tests:

      {:ok, _pid} = TodosMcp.InMemoryStore.start_link(name: :test_store)
      TodosMcp.InMemoryStore.insert(%Todo{id: "123", title: "Test"}, :test_store)
  """

  use Agent

  @default_name __MODULE__

  @doc """
  Start the in-memory store.

  ## Options

  - `:name` - Process name (default: `TodosMcp.InMemoryStore`)
  - `:initial` - Initial list of todos (default: `[]`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    initial = Keyword.get(opts, :initial, [])

    initial_state =
      initial
      |> Enum.map(fn todo -> {todo.id, todo} end)
      |> Map.new()

    Agent.start_link(fn -> initial_state end, name: name)
  end

  @doc "Stop the store"
  def stop(name \\ @default_name) do
    Agent.stop(name)
  end

  @doc "Clear all todos"
  def clear(name \\ @default_name) do
    Agent.update(name, fn _ -> %{} end)
  end

  @doc "Get all todos as a list"
  def all(name \\ @default_name) do
    Agent.get(name, &Map.values/1)
  end

  @doc "Get a todo by ID"
  def get(id, name \\ @default_name) do
    Agent.get(name, &Map.get(&1, id))
  end

  @doc "Insert a todo"
  def insert(todo, name \\ @default_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    todo =
      todo
      |> Map.put(:inserted_at, todo.inserted_at || now)
      |> Map.put(:updated_at, todo.updated_at || now)

    Agent.update(name, &Map.put(&1, todo.id, todo))
    {:ok, todo}
  end

  @doc "Update a todo"
  def update(todo, name \\ @default_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    todo = Map.put(todo, :updated_at, now)

    Agent.update(name, &Map.put(&1, todo.id, todo))
    {:ok, todo}
  end

  @doc "Delete a todo by ID"
  def delete(id, name \\ @default_name) do
    todo = get(id, name)

    if todo do
      Agent.update(name, &Map.delete(&1, id))
      {:ok, todo}
    else
      {:error, :not_found}
    end
  end

  @doc "Count all todos"
  def count(name \\ @default_name) do
    Agent.get(name, &map_size/1)
  end

  @doc "Count todos matching a predicate"
  def count_where(predicate, name \\ @default_name) do
    Agent.get(name, fn state ->
      state
      |> Map.values()
      |> Enum.count(predicate)
    end)
  end

  @doc "Filter todos by a predicate"
  def filter(predicate, name \\ @default_name) do
    Agent.get(name, fn state ->
      state
      |> Map.values()
      |> Enum.filter(predicate)
    end)
  end

  @doc "Update all todos matching a predicate"
  def update_where(predicate, update_fn, name \\ @default_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Agent.get_and_update(name, fn state ->
      {updated, new_state} =
        Enum.reduce(state, {[], state}, fn {id, todo}, {acc, st} ->
          if predicate.(todo) do
            updated_todo =
              todo
              |> update_fn.()
              |> Map.put(:updated_at, now)

            {[updated_todo | acc], Map.put(st, id, updated_todo)}
          else
            {acc, st}
          end
        end)

      {Enum.reverse(updated), new_state}
    end)
  end

  @doc "Delete all todos matching a predicate"
  def delete_where(predicate, name \\ @default_name) do
    Agent.get_and_update(name, fn state ->
      {deleted, new_state} =
        Enum.reduce(state, {[], state}, fn {id, todo}, {acc, st} ->
          if predicate.(todo) do
            {[todo | acc], Map.delete(st, id)}
          else
            {acc, st}
          end
        end)

      {Enum.reverse(deleted), new_state}
    end)
  end
end
