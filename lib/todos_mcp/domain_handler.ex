defmodule TodosMcp.DomainHandler do
  @moduledoc """
  Domain handler for todo commands and queries.

  Handles all domain operations using Skuld effects:
  - DataAccess (via Query effect) for reads
  - EctoPersist for writes
  - EventAccumulator for domain events (future)

  This module is used with `Skuld.Effects.Command.with_handler/2`:

      comp do
        result <- Command.execute(%CreateTodo{title: "Buy milk"})
        result
      end
      |> Command.with_handler(&DomainHandler.handle/1)
      |> Query.with_handler(%{DataAccess.Impl => :direct})
      |> EctoPersist.with_handler(Repo)
      |> Throw.with_handler()
      |> Comp.run!()
  """

  use Skuld.Syntax

  alias TodosMcp.{Todo, DataAccess}
  alias Skuld.Effects.{EctoPersist, Fresh}

  alias TodosMcp.Commands.{
    CreateTodo,
    UpdateTodo,
    ToggleTodo,
    DeleteTodo,
    CompleteAll,
    ClearCompleted
  }

  alias TodosMcp.Queries.{
    ListTodos,
    GetTodo,
    SearchTodos,
    GetStats
  }

  #############################################################################
  ## Commands (mutations)
  #############################################################################

  defcomp handle(%CreateTodo{} = cmd) do
    id <- Fresh.fresh_uuid()

    attrs = %{
      id: id,
      title: cmd.title,
      description: cmd.description,
      priority: cmd.priority,
      due_date: cmd.due_date,
      tags: cmd.tags
    }

    changeset = Todo.changeset(%Todo{}, attrs)
    todo <- EctoPersist.insert(changeset)
    {:ok, todo}
  end

  defcomp handle(%UpdateTodo{id: id} = cmd) do
    todo <- DataAccess.get_todo!(id)

    attrs =
      %{
        title: cmd.title,
        description: cmd.description,
        priority: cmd.priority,
        due_date: cmd.due_date,
        tags: cmd.tags
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    changeset = Todo.changeset(todo, attrs)
    updated <- EctoPersist.update(changeset)
    {:ok, updated}
  end

  defcomp handle(%ToggleTodo{id: id}) do
    todo <- DataAccess.get_todo!(id)
    changeset = Todo.changeset(todo, %{completed: not todo.completed})
    updated <- EctoPersist.update(changeset)
    {:ok, updated}
  end

  defcomp handle(%DeleteTodo{id: id}) do
    todo <- DataAccess.get_todo!(id)
    result <- EctoPersist.delete(todo)
    result
  end

  defcomp handle(%CompleteAll{}) do
    todos <- DataAccess.list_incomplete()
    changesets = Enum.map(todos, &Todo.changeset(&1, %{completed: true}))
    {count, _} <- EctoPersist.update_all(Todo, changesets)
    {:ok, %{updated: count}}
  end

  defcomp handle(%ClearCompleted{}) do
    todos <- DataAccess.list_completed()
    {count, _} <- EctoPersist.delete_all(Todo, todos)
    {:ok, %{deleted: count}}
  end

  #############################################################################
  ## Queries (reads)
  #############################################################################

  defcomp handle(%ListTodos{filter: filter, sort_by: sort_by, sort_order: sort_order}) do
    todos <- DataAccess.list_todos(%{filter: filter, sort_by: sort_by, sort_order: sort_order})
    {:ok, todos}
  end

  defcomp handle(%GetTodo{id: id}) do
    result <- DataAccess.get_todo(id)

    case result do
      {:ok, todo} -> {:ok, todo}
      {:error, {:not_found, _, _}} -> {:error, :not_found}
    end
  end

  defcomp handle(%SearchTodos{query: query, limit: limit}) do
    todos <- DataAccess.search_todos(query, limit)
    {:ok, todos}
  end

  defcomp handle(%GetStats{}) do
    stats <- DataAccess.get_stats()
    {:ok, stats}
  end
end
