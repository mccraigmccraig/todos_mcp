defmodule TodosMcp.Generators do
  @moduledoc """
  StreamData generators for property-based testing of Todos.Handler.

  Provides generators for:
  - Primitive types (priority, filter, sort options)
  - Command structs (CreateTodo, UpdateTodo, etc.)
  - Query structs (ListTodos, SearchTodos, etc.)
  - Todo structs (for seeding initial state)
  """

  use ExUnitProperties

  alias TodosMcp.Todos.Todo

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
  ## Primitives
  #############################################################################

  @doc "Generate a priority atom"
  def priority do
    member_of([:low, :medium, :high])
  end

  @doc "Generate a filter atom"
  def filter do
    member_of([:all, :active, :completed])
  end

  @doc "Generate a sort_by atom"
  def sort_by do
    member_of([:inserted_at, :title, :priority, :due_date])
  end

  @doc "Generate a sort_order atom"
  def sort_order do
    member_of([:asc, :desc])
  end

  @doc "Generate a valid todo title (non-empty, reasonable length)"
  def todo_title do
    string(:alphanumeric, min_length: 1, max_length: 100)
  end

  @doc "Generate a todo description"
  def todo_description do
    string(:alphanumeric, max_length: 200)
  end

  @doc "Generate a UUID-like string"
  def todo_id do
    # Generate a proper UUID v4 format
    gen all(
          a <- string(:alphanumeric, length: 8),
          b <- string(:alphanumeric, length: 4),
          c <- string(:alphanumeric, length: 4),
          d <- string(:alphanumeric, length: 4),
          e <- string(:alphanumeric, length: 12)
        ) do
      String.downcase("#{a}-#{b}-#{c}-#{d}-#{e}")
    end
  end

  #############################################################################
  ## Todo Struct (for seeding initial state)
  #############################################################################

  @doc "Generate a Todo struct with random data"
  def todo(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "test-tenant")

    gen all(
          id <- todo_id(),
          title <- todo_title(),
          description <- todo_description(),
          completed <- boolean(),
          priority <- priority()
        ) do
      now = DateTime.utc_now()

      %Todo{
        id: id,
        tenant_id: tenant_id,
        title: title,
        description: description,
        completed: completed,
        priority: priority,
        tags: [],
        inserted_at: now,
        updated_at: now
      }
    end
  end

  @doc "Generate a list of Todo structs"
  def todos(opts \\ []) do
    {list_opts, todo_opts} = Keyword.split(opts, [:min_length, :max_length, :length])
    list_of(todo(todo_opts), list_opts)
  end

  #############################################################################
  ## Command Generators
  #############################################################################

  @doc "Generate a CreateTodo command"
  def create_todo do
    gen all(
          title <- todo_title(),
          description <- todo_description(),
          priority <- priority()
        ) do
      %CreateTodo{
        title: title,
        description: description,
        priority: priority
      }
    end
  end

  @doc "Generate an UpdateTodo command for one of the existing IDs"
  def update_todo(existing_ids) when is_list(existing_ids) and existing_ids != [] do
    gen all(
          id <- member_of(existing_ids),
          title <- one_of([constant(nil), todo_title()]),
          description <- one_of([constant(nil), todo_description()]),
          priority <- one_of([constant(nil), priority()])
        ) do
      %UpdateTodo{
        id: id,
        title: title,
        description: description,
        priority: priority
      }
    end
  end

  @doc "Generate a ToggleTodo command for one of the existing IDs"
  def toggle_todo(existing_ids) when is_list(existing_ids) and existing_ids != [] do
    gen all(id <- member_of(existing_ids)) do
      %ToggleTodo{id: id}
    end
  end

  @doc "Generate a DeleteTodo command for one of the existing IDs"
  def delete_todo(existing_ids) when is_list(existing_ids) and existing_ids != [] do
    gen all(id <- member_of(existing_ids)) do
      %DeleteTodo{id: id}
    end
  end

  @doc "Generate a CompleteAll command"
  def complete_all do
    constant(%CompleteAll{})
  end

  @doc "Generate a ClearCompleted command"
  def clear_completed do
    constant(%ClearCompleted{})
  end

  #############################################################################
  ## Query Generators
  #############################################################################

  @doc "Generate a ListTodos query"
  def list_todos do
    gen all(
          filter <- filter(),
          sort_by <- sort_by(),
          sort_order <- sort_order()
        ) do
      %ListTodos{
        filter: filter,
        sort_by: sort_by,
        sort_order: sort_order
      }
    end
  end

  @doc "Generate a GetTodo query for one of the existing IDs"
  def get_todo(existing_ids) when is_list(existing_ids) and existing_ids != [] do
    gen all(id <- member_of(existing_ids)) do
      %GetTodo{id: id}
    end
  end

  @doc "Generate a SearchTodos query"
  def search_todos do
    gen all(
          query <- string(:alphanumeric, min_length: 1, max_length: 20),
          limit <- integer(1..100)
        ) do
      %SearchTodos{
        query: query,
        limit: limit
      }
    end
  end

  @doc "Generate a GetStats query"
  def get_stats do
    constant(%GetStats{})
  end
end
