defmodule TodosMcp.Todos.Handlers do
  @moduledoc """
  Domain handlers for todo commands and queries.

  Handles all domain operations using Skuld effects:
  - Repository (via Query effect) for reads
  - ChangesetPersist for writes
  - Reader (CommandContext) for tenant isolation
  - EventAccumulator for domain events (future)

  This module is used with `Skuld.Effects.Command.with_handler/2`:

      comp do
        result <- Command.execute(%CreateTodo{title: "Buy milk"})
        result
      end
      |> Command.with_handler(&Todos.Handlers.handle/1)
      |> Reader.with_handler(%CommandContext{tenant_id: "tenant-123"}, tag: CommandContext)
      |> Query.with_handler(%{Todos.Repository.Ecto => :direct})
      |> ChangesetPersist.Ecto.with_handler(Repo)
      |> Throw.with_handler()
      |> Comp.run!()
  """

  use Skuld.Syntax

  alias TodosMcp.CommandContext
  alias TodosMcp.Todos.{Todo, Repository}
  alias Skuld.Effects.{ChangesetPersist, Fresh, Reader}

  alias TodosMcp.Todos.Commands.{
    CreateTodo,
    UpdateTodo,
    ToggleTodo,
    DeleteTodo,
    CompleteAll,
    ClearCompleted
  }

  alias TodosMcp.Todos.Queries.{
    ListTodos,
    GetTodo,
    SearchTodos,
    GetStats
  }

  #############################################################################
  ## Commands (mutations)
  #############################################################################

  defcomp handle(%CreateTodo{} = cmd) do
    ctx <- Reader.ask(CommandContext)
    id <- Fresh.fresh_uuid()

    attrs = %{
      id: id,
      tenant_id: ctx.tenant_id,
      title: cmd.title,
      description: cmd.description,
      priority: cmd.priority,
      due_date: cmd.due_date,
      tags: cmd.tags
    }

    changeset = Todo.changeset(%Todo{}, attrs)
    todo <- ChangesetPersist.insert(changeset)
    {:ok, todo}
  end

  defcomp handle(%UpdateTodo{id: id} = cmd) do
    ctx <- Reader.ask(CommandContext)
    todo <- Repository.get_todo!(ctx.tenant_id, id)

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
    updated <- ChangesetPersist.update(changeset)
    {:ok, updated}
  end

  defcomp handle(%ToggleTodo{id: id}) do
    ctx <- Reader.ask(CommandContext)
    todo <- Repository.get_todo!(ctx.tenant_id, id)
    changeset = Todo.changeset(todo, %{completed: not todo.completed})
    updated <- ChangesetPersist.update(changeset)
    {:ok, updated}
  end

  defcomp handle(%DeleteTodo{id: id}) do
    ctx <- Reader.ask(CommandContext)
    todo <- Repository.get_todo!(ctx.tenant_id, id)
    result <- ChangesetPersist.delete(todo)
    result
  end

  defcomp handle(%CompleteAll{}) do
    ctx <- Reader.ask(CommandContext)
    todos <- Repository.list_incomplete(ctx.tenant_id)
    changesets = Enum.map(todos, &Todo.changeset(&1, %{completed: true}))
    {count, _} <- ChangesetPersist.update_all(Todo, changesets)
    {:ok, %{updated: count}}
  end

  defcomp handle(%ClearCompleted{}) do
    ctx <- Reader.ask(CommandContext)
    todos <- Repository.list_completed(ctx.tenant_id)
    {count, _} <- ChangesetPersist.delete_all(Todo, todos)
    {:ok, %{deleted: count}}
  end

  #############################################################################
  ## Queries (reads)
  #############################################################################

  defcomp handle(%ListTodos{filter: filter, sort_by: sort_by, sort_order: sort_order}) do
    ctx <- Reader.ask(CommandContext)

    todos <-
      Repository.list_todos(ctx.tenant_id, %{
        filter: filter,
        sort_by: sort_by,
        sort_order: sort_order
      })

    {:ok, todos}
  end

  defcomp handle(%GetTodo{id: id}) do
    ctx <- Reader.ask(CommandContext)
    result <- Repository.get_todo(ctx.tenant_id, id)

    case result do
      {:ok, todo} -> {:ok, todo}
      {:error, {:not_found, _, _}} -> {:error, :not_found}
    end
  end

  defcomp handle(%SearchTodos{query: query, limit: limit}) do
    ctx <- Reader.ask(CommandContext)
    todos <- Repository.search_todos(ctx.tenant_id, query, limit)
    {:ok, todos}
  end

  defcomp handle(%GetStats{}) do
    ctx <- Reader.ask(CommandContext)
    stats <- Repository.get_stats(ctx.tenant_id)
    {:ok, stats}
  end
end
