defmodule TodosMcpWeb.TodoLive do
  @moduledoc """
  LiveView for the todo list interface.

  All actions dispatch through TodosMcp.Run which handles the
  Skuld effect handler stack.
  """
  use TodosMcpWeb, :live_view

  alias TodosMcp.Run
  alias TodosMcp.Commands.{CreateTodo, ToggleTodo, DeleteTodo, ClearCompleted, CompleteAll}
  alias TodosMcp.Queries.{ListTodos, GetStats}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, todos} = Run.execute(%ListTodos{})
    {:ok, stats} = Run.execute(%GetStats{})

    {:ok,
     assign(socket,
       todos: todos,
       stats: stats,
       filter: :all,
       new_todo_title: ""
     )}
  end

  @impl true
  def handle_event("create", %{"title" => title}, socket) when title != "" do
    case Run.execute(%CreateTodo{title: title}) do
      {:ok, _todo} ->
        {:noreply, socket |> assign(new_todo_title: "") |> reload_todos()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create todo")}
    end
  end

  def handle_event("create", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    case Run.execute(%ToggleTodo{id: String.to_integer(id)}) do
      {:ok, _todo} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle todo")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Run.execute(%DeleteTodo{id: String.to_integer(id)}) do
      {:ok, _todo} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete todo")}
    end
  end

  def handle_event("clear_completed", _params, socket) do
    case Run.execute(%ClearCompleted{}) do
      {:ok, _result} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear completed")}
    end
  end

  def handle_event("complete_all", _params, socket) do
    case Run.execute(%CompleteAll{}) do
      {:ok, _result} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to complete all")}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    filter_atom = String.to_existing_atom(filter)
    {:ok, todos} = Run.execute(%ListTodos{filter: filter_atom})

    {:noreply, assign(socket, todos: todos, filter: filter_atom)}
  end

  def handle_event("update_new_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, new_todo_title: title)}
  end

  defp reload_todos(socket) do
    {:ok, todos} = Run.execute(%ListTodos{filter: socket.assigns.filter})
    {:ok, stats} = Run.execute(%GetStats{})
    assign(socket, todos: todos, stats: stats)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-6">Todos</h1>

      <%!-- New todo form --%>
      <form phx-submit="create" class="mb-6">
        <div class="flex gap-2">
          <input
            type="text"
            name="title"
            value={@new_todo_title}
            phx-change="update_new_title"
            placeholder="What needs to be done?"
            class="flex-1 px-4 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
            autofocus
          />
          <button
            type="submit"
            class="px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            Add
          </button>
        </div>
      </form>

      <%!-- Stats and bulk actions --%>
      <div class="flex justify-between items-center mb-4 text-sm text-gray-600">
        <span>
          {@stats.active} active, {@stats.completed} completed
        </span>
        <div class="flex gap-2">
          <button
            :if={@stats.active > 0}
            phx-click="complete_all"
            class="text-blue-500 hover:underline"
          >
            Complete all
          </button>
          <button
            :if={@stats.completed > 0}
            phx-click="clear_completed"
            class="text-red-500 hover:underline"
          >
            Clear completed
          </button>
        </div>
      </div>

      <%!-- Filter tabs --%>
      <div class="flex gap-4 mb-4 border-b">
        <button
          :for={filter <- [:all, :active, :completed]}
          phx-click="filter"
          phx-value-filter={filter}
          class={[
            "pb-2 px-1",
            @filter == filter && "border-b-2 border-blue-500 text-blue-500",
            @filter != filter && "text-gray-500 hover:text-gray-700"
          ]}
        >
          {String.capitalize(to_string(filter))}
        </button>
      </div>

      <%!-- Todo list --%>
      <ul class="space-y-2">
        <li :for={todo <- @todos} class="flex items-center gap-3 p-3 bg-gray-50 rounded-lg group">
          <input
            type="checkbox"
            checked={todo.completed}
            phx-click="toggle"
            phx-value-id={todo.id}
            class="w-5 h-5 rounded border-gray-300 text-blue-500 focus:ring-blue-500"
          />
          <span class={["flex-1", todo.completed && "line-through text-gray-400"]}>
            {todo.title}
          </span>
          <span
            :if={todo.priority != :medium}
            class={[
              "text-xs px-2 py-1 rounded",
              todo.priority == :high && "bg-red-100 text-red-700",
              todo.priority == :low && "bg-gray-100 text-gray-600"
            ]}
          >
            {todo.priority}
          </span>
          <button
            phx-click="delete"
            phx-value-id={todo.id}
            class="opacity-0 group-hover:opacity-100 text-red-500 hover:text-red-700"
          >
            <.icon name="hero-trash" class="w-5 h-5" />
          </button>
        </li>
      </ul>

      <p :if={@todos == []} class="text-center text-gray-400 py-8">
        <%= case @filter do %>
          <% :all -> %>
            No todos yet. Add one above!
          <% :active -> %>
            No active todos.
          <% :completed -> %>
            No completed todos.
        <% end %>
      </p>
    </div>
    """
  end
end
