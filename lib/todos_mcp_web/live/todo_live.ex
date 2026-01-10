defmodule TodosMcpWeb.TodoLive do
  @moduledoc """
  LiveView for the todo list interface with LLM chat sidebar.

  All actions dispatch through TodosMcp.Run which handles the
  Skuld effect handler stack.
  """
  use TodosMcpWeb, :live_view

  alias TodosMcp.Run
  alias TodosMcp.Llm.Conversation
  alias TodosMcp.Commands.{CreateTodo, ToggleTodo, DeleteTodo, ClearCompleted, CompleteAll}
  alias TodosMcp.Queries.{ListTodos, GetStats}

  @impl true
  def mount(_params, session, socket) do
    {:ok, todos} = Run.execute(%ListTodos{})
    {:ok, stats} = Run.execute(%GetStats{})

    # Get API key from session (atom key) or environment
    api_key = session[:api_key] || System.get_env("ANTHROPIC_API_KEY")

    api_key_source =
      cond do
        session[:api_key] -> :session
        System.get_env("ANTHROPIC_API_KEY") -> :env
        true -> nil
      end

    {:ok,
     assign(socket,
       todos: todos,
       stats: stats,
       filter: :all,
       new_todo_title: "",
       sidebar_open: true,
       api_key: api_key,
       api_key_source: api_key_source,
       chat_messages: [],
       chat_input: "",
       chat_loading: false,
       chat_error: nil,
       conversation: if(api_key, do: Conversation.new(api_key: api_key), else: nil)
     )}
  end

  # All handle_event clauses grouped together

  @impl true
  def handle_event("chat_send", %{"message" => message}, socket) when message != "" do
    if socket.assigns.conversation do
      # Add user message to UI immediately
      user_msg = %{role: :user, content: message}
      messages = socket.assigns.chat_messages ++ [user_msg]

      # Clear input and show loading
      socket =
        socket
        |> assign(chat_messages: messages, chat_input: "", chat_loading: true, chat_error: nil)

      # Send async to avoid blocking
      conv = socket.assigns.conversation
      pid = self()

      Task.start(fn ->
        result = Conversation.send_message(conv, message)
        send(pid, {:llm_response, result})
      end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, chat_error: "API key not configured")}
    end
  end

  def handle_event("chat_send", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("chat_input", %{"message" => message}, socket) do
    {:noreply, assign(socket, chat_input: message)}
  end

  def handle_event("chat_clear", _params, socket) do
    socket =
      if socket.assigns.conversation do
        conv = Conversation.clear_history(socket.assigns.conversation)
        assign(socket, conversation: conv, chat_messages: [], chat_error: nil)
      else
        assign(socket, chat_messages: [], chat_error: nil)
      end

    {:noreply, socket}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

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

  # Handle LLM response
  @impl true
  def handle_info({:llm_response, result}, socket) do
    socket =
      case result do
        {:ok, conv, response} ->
          # Add assistant message with tool executions
          assistant_msg = %{
            role: :assistant,
            content: response.text,
            tool_executions: response.tool_executions
          }

          messages = socket.assigns.chat_messages ++ [assistant_msg]

          # Refresh todos if any tools executed
          socket =
            if response.tool_executions != [] do
              reload_todos(socket)
            else
              socket
            end

          assign(socket,
            conversation: conv,
            chat_messages: messages,
            chat_loading: false
          )

        {:error, reason} ->
          assign(socket,
            chat_loading: false,
            chat_error: format_error(reason)
          )
      end

    {:noreply, socket}
  end

  defp reload_todos(socket) do
    {:ok, todos} = Run.execute(%ListTodos{filter: socket.assigns.filter})
    {:ok, stats} = Run.execute(%GetStats{})
    assign(socket, todos: todos, stats: stats)
  end

  defp format_error({:api_error, status, body}) do
    "API error (#{status}): #{inspect(body["error"]["message"] || body)}"
  end

  defp format_error({:request_failed, reason}) do
    "Request failed: #{inspect(reason)}"
  end

  defp format_error(:max_iterations_exceeded) do
    "Too many tool calls. Please try again."
  end

  defp format_error(reason) do
    "Error: #{inspect(reason)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-80px)]">
      <%!-- Main content --%>
      <div class={["flex-1 overflow-y-auto", @sidebar_open && "mr-80"]}>
        <div class="max-w-2xl mx-auto p-6">
          <div class="flex justify-between items-center mb-6">
            <h1 class="text-3xl font-bold">Todos</h1>
            <button
              phx-click="toggle_sidebar"
              class="text-gray-500 hover:text-gray-700"
              title={if @sidebar_open, do: "Hide chat", else: "Show chat"}
            >
              <.icon name={if @sidebar_open, do: "hero-chat-bubble-left-right-solid", else: "hero-chat-bubble-left-right"} class="w-6 h-6" />
            </button>
          </div>

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
      </div>

      <%!-- Chat Sidebar --%>
      <div
        :if={@sidebar_open}
        class="fixed right-0 top-[64px] bottom-0 w-80 flex flex-col bg-base-200 border-l border-base-300"
      >
        <%!-- Header --%>
        <div class="flex items-center justify-between p-3 border-b border-base-300">
          <h2 class="font-semibold">AI Assistant</h2>
          <button
            :if={@chat_messages != []}
            phx-click="chat_clear"
            class="text-sm text-gray-500 hover:text-gray-700"
          >
            Clear
          </button>
        </div>

        <%!-- API Key Status --%>
        <div :if={!@api_key} class="p-4 bg-amber-50 text-amber-800 text-sm">
          <p class="font-medium">API Key Required</p>
          <p class="mt-1">Configure your Anthropic API key to enable chat.</p>
          <button
            type="button"
            onclick="document.getElementById('api-key-modal').showModal()"
            class="mt-2 text-blue-600 hover:underline"
          >
            Configure API Key
          </button>
        </div>

        <div :if={@api_key} class="px-3 py-2 text-xs text-gray-500 border-b border-base-300 flex items-center justify-between">
          <span>
            API Key: {if @api_key_source == :session, do: "configured", else: "from env"}
          </span>
          <button
            type="button"
            onclick="document.getElementById('api-key-modal').showModal()"
            class="hover:text-gray-700"
            title="Settings"
          >
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
          </button>
        </div>

        <%!-- Messages --%>
        <div class="flex-1 overflow-y-auto p-3 space-y-3" id="chat-messages">
          <div :for={msg <- @chat_messages} class={message_class(msg.role)}>
            <div class="text-xs text-gray-500 mb-1">
              {if msg.role == :user, do: "You", else: "Assistant"}
            </div>
            <div class="whitespace-pre-wrap text-sm">{msg.content}</div>

            <%!-- Tool executions --%>
            <div :if={msg[:tool_executions] && msg.tool_executions != []} class="mt-2 space-y-1">
              <div
                :for={exec <- msg.tool_executions}
                class="text-xs bg-base-300 rounded px-2 py-1"
              >
                <span class="font-medium">{exec.tool}</span>
                <span :if={match?({:ok, _}, exec.result)} class="text-green-600 ml-1">ok</span>
                <span :if={match?({:error, _}, exec.result)} class="text-red-600 ml-1">error</span>
              </div>
            </div>
          </div>

          <%!-- Loading indicator --%>
          <div :if={@chat_loading} class="flex items-center gap-2 text-gray-500">
            <span class="loading loading-dots loading-sm"></span>
            <span class="text-sm">Thinking...</span>
          </div>
        </div>

        <%!-- Error display --%>
        <div :if={@chat_error} class="px-3 py-2 bg-red-50 text-red-700 text-sm">
          {@chat_error}
        </div>

        <%!-- Input form --%>
        <form phx-submit="chat_send" class="p-3 border-t border-base-300">
          <div class="flex gap-2">
            <input
              type="text"
              name="message"
              value={@chat_input}
              phx-change="chat_input"
              placeholder={if @api_key, do: "Ask me to manage your todos...", else: "Configure API key first"}
              disabled={!@api_key || @chat_loading}
              class="flex-1 px-3 py-2 text-sm border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100"
              autocomplete="off"
            />
            <button
              type="submit"
              disabled={!@api_key || @chat_loading || @chat_input == ""}
              class="px-3 py-2 bg-blue-500 text-white text-sm rounded-lg hover:bg-blue-600 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Send
            </button>
          </div>
        </form>
      </div>

      <%!-- API Key Settings Modal --%>
      <.modal id="api-key-modal">
        <:title>API Key Settings</:title>

        <p class="text-sm text-gray-600 mb-4">
          Enter your Anthropic API key to enable the AI assistant.
          Your key is stored in your browser session and never sent to our servers.
        </p>

        <form action={~p"/settings/api-key"} method="post" class="space-y-4">
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <div>
            <label for="api_key" class="block text-sm font-medium mb-1">API Key</label>
            <input
              type="password"
              name="api_key"
              id="api_key"
              placeholder="sk-ant-..."
              class="w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              autocomplete="off"
            />
          </div>

          <div class="flex gap-2">
            <button
              type="submit"
              class="flex-1 px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600"
            >
              Save
            </button>
          </div>
        </form>

        <div :if={@api_key && @api_key_source == :session} class="mt-4 pt-4 border-t">
          <form action={~p"/settings/api-key"} method="post">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="_method" value="delete" />
            <button
              type="submit"
              class="text-sm text-red-600 hover:underline"
            >
              Clear saved API key
            </button>
          </form>
        </div>

        <p :if={@api_key_source == :env} class="mt-4 pt-4 border-t text-xs text-gray-500">
          Currently using API key from ANTHROPIC_API_KEY environment variable.
          Setting a key here will override it for this session.
        </p>
      </.modal>
    </div>
    """
  end

  defp message_class(:user), do: "bg-blue-50 rounded-lg p-3 ml-4"
  defp message_class(:assistant), do: "bg-base-100 rounded-lg p-3 mr-4"
  defp message_class(_), do: "bg-base-100 rounded-lg p-3"
end
