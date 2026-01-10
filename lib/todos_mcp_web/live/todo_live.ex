defmodule TodosMcpWeb.TodoLive do
  @moduledoc """
  LiveView for the todo list interface with LLM chat sidebar.

  All actions dispatch through TodosMcp.Run which handles the
  Skuld effect handler stack.
  """
  use TodosMcpWeb, :live_view

  alias TodosMcp.Run
  alias TodosMcp.Llm.ConversationRunner
  alias TodosMcp.Commands.{CreateTodo, ToggleTodo, DeleteTodo, ClearCompleted, CompleteAll}
  alias TodosMcp.Queries.{ListTodos, GetStats}
  alias TodosMcp.Effects.Transcribe
  alias TodosMcp.Effects.Transcribe.GroqHandler

  # Allowed audio formats for voice recording (ensures atoms exist for to_existing_atom)
  @allowed_audio_formats [:webm, :mp3, :wav, :ogg]

  @impl true
  def mount(_params, session, socket) do
    {:ok, todos} = Run.execute(%ListTodos{})
    {:ok, stats} = Run.execute(%GetStats{})

    # Get API key from session (string key in LiveView) or environment
    session_api_key = session["api_key"]
    env_api_key = System.get_env("ANTHROPIC_API_KEY")
    api_key = session_api_key || env_api_key

    api_key_source =
      cond do
        session_api_key -> :session
        env_api_key -> :env
        true -> nil
      end

    # Groq API key for voice transcription (from session or environment)
    session_groq_key = session["groq_api_key"]
    env_groq_key = System.get_env("GROQ_API_KEY")
    groq_api_key = session_groq_key || env_groq_key

    # Initialize conversation runner (suspended at :await_user_input)
    runner =
      if api_key do
        case ConversationRunner.start(api_key: api_key) do
          {:ok, runner} -> runner
          {:error, _reason} -> nil
        end
      else
        nil
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
       groq_api_key: groq_api_key,
       chat_messages: [],
       chat_input: "",
       chat_loading: false,
       chat_error: nil,
       runner: runner,
       # Voice recording state
       is_recording: false,
       is_transcribing: false
     )}
  end

  # All handle_event clauses grouped together

  @impl true
  def handle_event("chat_send", %{"message" => message}, socket) when message != "" do
    if socket.assigns.runner do
      # Add user message to UI immediately
      user_msg = %{role: :user, content: message}
      messages = socket.assigns.chat_messages ++ [user_msg]

      # Clear input and show loading
      socket =
        socket
        |> assign(chat_messages: messages, chat_input: "", chat_loading: true, chat_error: nil)

      # Send async to avoid blocking (LLM calls can take seconds)
      runner = socket.assigns.runner
      pid = self()

      Task.start(fn ->
        result = ConversationRunner.send_message(runner, message)
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
    # Start a fresh conversation runner
    runner =
      if socket.assigns.api_key do
        case ConversationRunner.start(api_key: socket.assigns.api_key) do
          {:ok, runner} -> runner
          {:error, _reason} -> nil
        end
      else
        nil
      end

    {:noreply, assign(socket, runner: runner, chat_messages: [], chat_error: nil)}
  end

  # Voice recording events
  def handle_event("recording_started", _params, socket) do
    {:noreply, assign(socket, is_recording: true, chat_error: nil)}
  end

  def handle_event("recording_error", %{"error" => error}, socket) do
    {:noreply, assign(socket, is_recording: false, chat_error: "Microphone error: #{error}")}
  end

  def handle_event("audio_recorded", %{"audio" => base64_audio, "format" => format}, socket) do
    socket = assign(socket, is_recording: false, is_transcribing: true)

    if socket.assigns.groq_api_key do
      # Decode base64 audio and validate format
      audio_data = Base.decode64!(base64_audio)
      format_atom = String.to_existing_atom(format)

      if format_atom in @allowed_audio_formats do
        groq_key = socket.assigns.groq_api_key
        pid = self()

        # Transcribe async
        Task.start(fn ->
          result = transcribe_audio(audio_data, format_atom, groq_key)
          send(pid, {:transcription_result, result})
        end)

        {:noreply, socket}
      else
        {:noreply,
         assign(socket,
           is_transcribing: false,
           chat_error: "Unsupported audio format: #{format}"
         )}
      end
    else
      {:noreply,
       assign(socket,
         is_transcribing: false,
         chat_error: "Groq API key not configured for voice input"
       )}
    end
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
    case Run.execute(%ToggleTodo{id: id}) do
      {:ok, _todo} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle todo")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Run.execute(%DeleteTodo{id: id}) do
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

  # Handle LLM response from ConversationRunner
  @impl true
  def handle_info({:llm_response, result}, socket) do
    socket =
      case result do
        {:ok, response, updated_runner} ->
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
            runner: updated_runner,
            chat_messages: messages,
            chat_loading: false
          )

        {:error, reason, updated_runner} ->
          # Even on error, update the runner (it's back at :await_user_input)
          assign(socket,
            runner: updated_runner,
            chat_loading: false,
            chat_error: format_error(reason)
          )
      end

    {:noreply, socket}
  end

  # Handle transcription result - then send to LLM
  def handle_info({:transcription_result, result}, socket) do
    socket = assign(socket, is_transcribing: false)

    case result do
      {:ok, %{text: text}} when text != "" ->
        # We have transcribed text - now send it to the LLM as if user typed it
        # Reuse the chat_send logic
        if socket.assigns.runner do
          user_msg = %{role: :user, content: text}
          messages = socket.assigns.chat_messages ++ [user_msg]

          socket =
            assign(socket,
              chat_messages: messages,
              chat_input: "",
              chat_loading: true,
              chat_error: nil
            )

          runner = socket.assigns.runner
          pid = self()

          Task.start(fn ->
            result = ConversationRunner.send_message(runner, text)
            send(pid, {:llm_response, result})
          end)

          {:noreply, socket}
        else
          {:noreply, assign(socket, chat_error: "API key not configured")}
        end

      {:ok, %{text: ""}} ->
        {:noreply, assign(socket, chat_error: "No speech detected")}

      {:error, reason} ->
        {:noreply, assign(socket, chat_error: format_transcription_error(reason))}

      # Handle unexpected computation errors (e.g., Skuld.Comp.Throw)
      _other ->
        {:noreply, assign(socket, chat_error: "Transcription failed: unexpected error")}
    end
  end

  defp reload_todos(socket) do
    {:ok, todos} = Run.execute(%ListTodos{filter: socket.assigns.filter})
    {:ok, stats} = Run.execute(%GetStats{})
    assign(socket, todos: todos, stats: stats)
  end

  # Transcribe audio using Groq Whisper via the Transcribe effect
  defp transcribe_audio(audio_data, format, api_key) do
    alias Skuld.Comp

    try do
      Transcribe.transcribe(audio_data, format: format)
      |> Transcribe.with_handler(GroqHandler.handler(api_key: api_key))
      |> Comp.run!()
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
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

  defp format_transcription_error({:api_error, status, body}) do
    "Transcription error (#{status}): #{inspect(body["error"]["message"] || body)}"
  end

  defp format_transcription_error({:request_failed, reason}) do
    "Transcription failed: #{inspect(reason)}"
  end

  defp format_transcription_error(reason) do
    "Transcription error: #{inspect(reason)}"
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
        <div class="flex-1 overflow-y-auto p-3 space-y-3" id="chat-messages" phx-hook="ScrollToBottom">
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

          <%!-- Transcribing indicator --%>
          <div :if={@is_transcribing} class="flex items-center gap-2 text-gray-500">
            <span class="loading loading-dots loading-sm"></span>
            <span class="text-sm">Transcribing...</span>
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
              id="chat-input"
              value={@chat_input}
              phx-change="chat_input"
              phx-hook="MaintainFocus"
              placeholder={if @api_key, do: "Ask me to manage your todos...", else: "Configure API key first"}
              disabled={!@api_key || @chat_loading || @is_transcribing}
              class="flex-1 px-3 py-2 text-sm border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100"
              autocomplete="off"
            />
            <%!-- Voice record button --%>
            <button
              type="button"
              id="voice-record-btn"
              phx-hook="AudioRecorder"
              disabled={!@api_key || !@groq_api_key || @chat_loading || @is_transcribing}
              title={cond do
                !@groq_api_key -> "Configure Groq API key for voice"
                @is_recording -> "Click to stop recording"
                true -> "Click to start voice recording"
              end}
              class={[
                "px-3 py-2 text-sm rounded-lg transition-colors",
                "disabled:opacity-50 disabled:cursor-not-allowed",
                @is_recording && "bg-red-500 text-white animate-pulse",
                !@is_recording && "bg-gray-200 text-gray-700 hover:bg-gray-300"
              ]}
            >
              <.icon name={if @is_recording, do: "hero-stop", else: "hero-microphone"} class="w-5 h-5" />
            </button>
            <button
              type="submit"
              disabled={!@api_key || @chat_loading || @is_transcribing || @chat_input == ""}
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
          Configure your API keys to enable AI features.
          Keys are stored in your browser session and never sent to our servers.
        </p>

        <form action={~p"/settings/api-key"} method="post" class="space-y-4">
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <div>
            <label for="api_key" class="block text-sm font-medium mb-1">
              Anthropic API Key
              <span class="text-gray-400 font-normal">(for chat)</span>
            </label>
            <input
              type="password"
              name="api_key"
              id="api_key"
              placeholder="sk-ant-..."
              class="w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              autocomplete="off"
            />
            <p :if={@api_key_source == :env} class="text-xs text-gray-500 mt-1">
              Using key from ANTHROPIC_API_KEY env var
            </p>
          </div>

          <div>
            <label for="groq_api_key" class="block text-sm font-medium mb-1">
              Groq API Key
              <span class="text-gray-400 font-normal">(for voice, optional)</span>
            </label>
            <input
              type="password"
              name="groq_api_key"
              id="groq_api_key"
              placeholder="gsk_..."
              class="w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              autocomplete="off"
            />
            <p :if={@groq_api_key && !@api_key_source} class="text-xs text-gray-500 mt-1">
              Using key from GROQ_API_KEY env var
            </p>
            <p class="text-xs text-gray-400 mt-1">
              <a href="https://console.groq.com/keys" target="_blank" class="text-blue-500 hover:underline">Create a free Groq API key</a>
            </p>
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
              Clear saved API keys
            </button>
          </form>
        </div>
      </.modal>
    </div>
    """
  end

  defp message_class(:user), do: "bg-blue-50 rounded-lg p-3 ml-4"
  defp message_class(:assistant), do: "bg-base-100 rounded-lg p-3 mr-4"
  defp message_class(_), do: "bg-base-100 rounded-lg p-3"
end
