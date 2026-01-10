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
  alias Skuld.Effects.EctoPersist

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

  def handle(%CreateTodo{} = cmd) do
    comp do
      attrs = %{
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
  end

  def handle(%UpdateTodo{id: id} = cmd) do
    comp do
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
  end

  def handle(%ToggleTodo{id: id}) do
    comp do
      todo <- DataAccess.get_todo!(id)
      changeset = Todo.changeset(todo, %{completed: not todo.completed})
      updated <- EctoPersist.update(changeset)
      {:ok, updated}
    end
  end

  def handle(%DeleteTodo{id: id}) do
    comp do
      todo <- DataAccess.get_todo!(id)
      result <- EctoPersist.delete(todo)
      result
    end
  end

  def handle(%CompleteAll{}) do
    comp do
      todos <- DataAccess.list_incomplete()
      changesets = Enum.map(todos, &Todo.changeset(&1, %{completed: true}))
      {count, _} <- EctoPersist.update_all(Todo, changesets)
      {:ok, %{updated: count}}
    end
  end

  def handle(%ClearCompleted{}) do
    comp do
      todos <- DataAccess.list_completed()
      {count, _} <- EctoPersist.delete_all(Todo, todos)
      {:ok, %{deleted: count}}
    end
  end

  #############################################################################
  ## Queries (reads)
  #############################################################################

  def handle(%ListTodos{filter: filter, sort_by: sort_by, sort_order: sort_order}) do
    comp do
      todos <- DataAccess.list_todos(%{filter: filter, sort_by: sort_by, sort_order: sort_order})
      {:ok, todos}
    end
  end

  def handle(%GetTodo{id: id}) do
    comp do
      todo <- DataAccess.get_todo(id)

      case todo do
        nil -> {:error, :not_found}
        todo -> {:ok, todo}
      end
    end
  end

  def handle(%SearchTodos{query: query, limit: limit}) do
    comp do
      todos <- DataAccess.search_todos(query, limit)
      {:ok, todos}
    end
  end

  def handle(%GetStats{}) do
    comp do
      stats <- DataAccess.get_stats()
      {:ok, stats}
    end
  end
end
