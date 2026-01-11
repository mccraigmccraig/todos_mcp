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
    # Get tenant_id from session or use default
    tenant_id = session["tenant_id"] || "default"

    {:ok, todos} = Run.execute(%ListTodos{}, tenant_id: tenant_id)
    {:ok, stats} = Run.execute(%GetStats{}, tenant_id: tenant_id)

    # Get API keys from session or environment
    # Anthropic (Claude)
    session_api_key = session["api_key"]
    env_api_key = System.get_env("ANTHROPIC_API_KEY")
    anthropic_api_key = session_api_key || env_api_key

    api_key_source =
      cond do
        session_api_key -> :session
        env_api_key -> :env
        true -> nil
      end

    # Gemini
    session_gemini_key = session["gemini_api_key"]
    env_gemini_key = System.get_env("GEMINI_API_KEY")
    gemini_api_key = session_gemini_key || env_gemini_key

    # Groq (for voice transcription)
    session_groq_key = session["groq_api_key"]
    env_groq_key = System.get_env("GROQ_API_KEY")
    groq_api_key = session_groq_key || env_groq_key

    # Build keys map for provider lookup
    api_keys = %{anthropic: anthropic_api_key, gemini: gemini_api_key, groq: groq_api_key}

    # Get saved provider from session, with validation
    saved_provider = session["selected_provider"]

    selected_provider =
      case saved_provider do
        "groq" when groq_api_key != nil ->
          :groq

        "gemini" when gemini_api_key != nil ->
          :gemini

        "claude" when anthropic_api_key != nil ->
          :claude

        # Fallback: prefer Claude, then Groq, then Gemini
        _ ->
          cond do
            anthropic_api_key -> :claude
            groq_api_key -> :groq
            gemini_api_key -> :gemini
            true -> :claude
          end
      end

    # Get API key for selected provider
    current_api_key = get_api_key_for_provider(selected_provider, api_keys)

    # Initialize conversation runner (suspended at :await_user_input)
    runner =
      if current_api_key do
        case ConversationRunner.start(
               api_key: current_api_key,
               provider: selected_provider,
               tenant_id: tenant_id
             ) do
          {:ok, runner} -> runner
          {:error, _reason} -> nil
        end
      else
        nil
      end

    {:ok,
     assign(socket,
       tenant_id: tenant_id,
       todos: todos,
       stats: stats,
       filter: :all,
       new_todo_title: "",
       sidebar_open: true,
       # API keys
       anthropic_api_key: anthropic_api_key,
       gemini_api_key: gemini_api_key,
       groq_api_key: groq_api_key,
       api_key_source: api_key_source,
       # Provider selection
       selected_provider: selected_provider,
       # Computed: current provider's API key (for UI convenience)
       api_key: current_api_key,
       # Chat state
       chat_messages: [],
       chat_input: "",
       chat_loading: false,
       chat_error: nil,
       runner: runner,
       # Voice recording state
       is_recording: false,
       is_transcribing: false,
       # Log modal state
       log_tab: :inspect,
       log_inspect: nil,
       log_json: nil
     )}
  end

  defp get_api_key_for_provider(:claude, keys), do: keys.anthropic
  defp get_api_key_for_provider(:gemini, keys), do: keys.gemini
  defp get_api_key_for_provider(:groq, keys), do: keys.groq
  defp get_api_key_for_provider(_, keys), do: keys.anthropic

  defp start_runner(assigns) do
    api_key = assigns.api_key

    if api_key do
      case ConversationRunner.start(
             api_key: api_key,
             provider: assigns.selected_provider,
             tenant_id: assigns.tenant_id
           ) do
        {:ok, runner} -> runner
        {:error, _reason} -> nil
      end
    else
      nil
    end
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
    # Start a fresh conversation runner with current provider
    runner = start_runner(socket.assigns)
    {:noreply, assign(socket, runner: runner, chat_messages: [], chat_error: nil)}
  end

  def handle_event("change_provider", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)

    api_keys = %{
      anthropic: socket.assigns.anthropic_api_key,
      gemini: socket.assigns.gemini_api_key,
      groq: socket.assigns.groq_api_key
    }

    api_key = get_api_key_for_provider(provider, api_keys)

    # Start a new runner with the selected provider (clears conversation)
    runner =
      if api_key do
        case ConversationRunner.start(
               api_key: api_key,
               provider: provider,
               tenant_id: socket.assigns.tenant_id
             ) do
          {:ok, runner} -> runner
          {:error, _reason} -> nil
        end
      else
        nil
      end

    {:noreply,
     socket
     |> assign(
       selected_provider: provider,
       api_key: api_key,
       runner: runner,
       chat_messages: [],
       chat_error: nil
     )
     |> push_event("save_provider", %{provider: Atom.to_string(provider)})}
  end

  def handle_event("show_log", _params, socket) do
    {log_inspect, log_json} =
      if socket.assigns.runner do
        {
          ConversationRunner.get_log_inspect(socket.assigns.runner),
          ConversationRunner.get_log_json(socket.assigns.runner)
        }
      else
        {"no runner", "null"}
      end

    {:noreply, assign(socket, log_inspect: log_inspect, log_json: log_json)}
  end

  def handle_event("log_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)
    {:noreply, assign(socket, log_tab: tab)}
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
    case run(socket, %CreateTodo{title: title}) do
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
    case run(socket, %ToggleTodo{id: id}) do
      {:ok, _todo} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle todo")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case run(socket, %DeleteTodo{id: id}) do
      {:ok, _todo} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete todo")}
    end
  end

  def handle_event("clear_completed", _params, socket) do
    case run(socket, %ClearCompleted{}) do
      {:ok, _result} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear completed")}
    end
  end

  def handle_event("complete_all", _params, socket) do
    case run(socket, %CompleteAll{}) do
      {:ok, _result} ->
        {:noreply, reload_todos(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to complete all")}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    filter_atom = String.to_existing_atom(filter)
    {:ok, todos} = run(socket, %ListTodos{filter: filter_atom})

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
    {:ok, todos} = run(socket, %ListTodos{filter: socket.assigns.filter})
    {:ok, stats} = run(socket, %GetStats{})
    assign(socket, todos: todos, stats: stats)
  end

  # Helper to run operations with tenant_id from socket
  defp run(socket, operation) do
    Run.execute(operation, tenant_id: socket.assigns.tenant_id)
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
            <h1 class="text-3xl font-bold text-base-content">Todos</h1>
            <button
              phx-click="toggle_sidebar"
              class="text-base-content/50 hover:text-base-content/80"
              title={if @sidebar_open, do: "Hide chat", else: "Show chat"}
            >
              <.icon
                name={
                  if @sidebar_open,
                    do: "hero-chat-bubble-left-right-solid",
                    else: "hero-chat-bubble-left-right"
                }
                class="w-6 h-6"
              />
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
                class="flex-1 px-4 py-2 bg-base-200 border border-base-300 text-base-content placeholder:text-base-content/40 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary"
                autofocus
              />
              <button
                type="submit"
                class="px-4 py-2 bg-primary text-primary-content rounded-lg hover:bg-primary/80 focus:outline-none focus:ring-2 focus:ring-primary"
              >
                Add
              </button>
            </div>
          </form>

          <%!-- Stats and bulk actions --%>
          <div class="flex justify-between items-center mb-4 text-sm text-base-content/60">
            <span>
              {@stats.active} active, {@stats.completed} completed
            </span>
            <div class="flex gap-2">
              <button
                :if={@stats.active > 0}
                phx-click="complete_all"
                class="text-primary hover:underline"
              >
                Complete all
              </button>
              <button
                :if={@stats.completed > 0}
                phx-click="clear_completed"
                class="text-error hover:underline"
              >
                Clear completed
              </button>
            </div>
          </div>

          <%!-- Filter tabs --%>
          <div class="flex gap-4 mb-4 border-b border-base-300">
            <button
              :for={filter <- [:all, :active, :completed]}
              phx-click="filter"
              phx-value-filter={filter}
              class={[
                "pb-2 px-1",
                @filter == filter && "border-b-2 border-primary text-primary",
                @filter != filter && "text-base-content/50 hover:text-base-content/80"
              ]}
            >
              {String.capitalize(to_string(filter))}
            </button>
          </div>

          <%!-- Todo list --%>
          <ul class="space-y-2">
            <li :for={todo <- @todos} class="flex items-center gap-3 p-3 bg-base-200 rounded-lg group">
              <input
                type="checkbox"
                checked={todo.completed}
                phx-click="toggle"
                phx-value-id={todo.id}
                class="w-5 h-5 rounded border-base-300 text-primary focus:ring-primary checkbox"
              />
              <div class="flex-1">
                <span class={["text-base-content", todo.completed && "line-through opacity-50"]}>
                  {todo.title}
                </span>
                <p :if={todo.description not in [nil, ""]} class={["text-sm mt-0.5 opacity-70", todo.completed && "line-through opacity-40"]}>
                  {todo.description}
                </p>
              </div>
              <span
                :if={todo.priority != :medium}
                class={[
                  "text-xs px-2 py-1 rounded",
                  todo.priority == :high && "bg-error/20 text-error",
                  todo.priority == :low && "bg-base-300 text-base-content/60"
                ]}
              >
                {todo.priority}
              </span>
              <button
                phx-click="delete"
                phx-value-id={todo.id}
                class="opacity-0 group-hover:opacity-100 text-error hover:text-error/80"
              >
                <.icon name="hero-trash" class="w-5 h-5" />
              </button>
            </li>
          </ul>

          <p :if={@todos == []} class="text-center text-base-content/40 py-8">
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
          <div class="flex items-center gap-2">
            <h2 class="font-semibold text-base-content">AI</h2>
            <form phx-change="change_provider">
              <select
                id="provider-select"
                phx-hook="ProviderSelector"
                name="provider"
                data-selected={Atom.to_string(@selected_provider)}
                class="select select-xs bg-base-300 border-base-100 text-base-content min-h-0 h-7 pl-2 pr-6"
              >
                <%= Phoenix.HTML.Form.options_for_select(
                  [
                    {"Claude #{if @anthropic_api_key, do: "", else: "(no key)"}", "claude"},
                    {"Groq #{if @groq_api_key, do: "", else: "(no key)"}", "groq"},
                    {"Gemini #{if @gemini_api_key, do: "", else: "(no key)"}", "gemini"}
                  ],
                  Atom.to_string(@selected_provider)
                ) %>
              </select>
            </form>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@runner}
              phx-click={JS.push("show_log") |> show_modal("log-modal")}
              class="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium text-accent bg-accent/10 rounded-md hover:bg-accent/20 transition-colors"
              title="View effect log"
            >
              <.icon name="hero-code-bracket" class="w-3.5 h-3.5" />
              <span>Log</span>
            </button>
            <button
              :if={@chat_messages != []}
              phx-click="chat_clear"
              class="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium text-base-content/70 bg-base-300 rounded-md hover:bg-base-100 transition-colors"
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              <span>Clear</span>
            </button>
          </div>
        </div>

        <%!-- API Key Status --%>
        <div :if={!@api_key} class="p-4 bg-warning/10 text-warning text-sm">
          <p class="font-medium">API Key Required</p>
          <p class="mt-1 text-warning/80">
            Configure your {provider_display_name(@selected_provider)} API key to enable chat.
          </p>
          <button
            type="button"
            phx-click={show_modal("api-key-modal")}
            class="mt-2 text-primary hover:underline"
          >
            Configure API Key
          </button>
        </div>

        <div
          :if={@api_key}
          class="px-3 py-2 text-xs text-base-content/50 border-b border-base-300 flex items-center justify-between"
        >
          <span>
            API Key: {if @api_key_source == :session, do: "configured", else: "from env"}
          </span>
          <button
            type="button"
            phx-click={show_modal("api-key-modal")}
            class="hover:text-base-content/80"
            title="Settings"
          >
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
          </button>
        </div>

        <%!-- Messages --%>
        <div class="flex-1 overflow-y-auto p-3 space-y-3" id="chat-messages" phx-hook="ScrollToBottom">
          <div :for={msg <- @chat_messages} class={message_class(msg.role)}>
            <div class="text-xs text-base-content/50 mb-1">
              {if msg.role == :user, do: "You", else: "Assistant"}
            </div>
            <div class="whitespace-pre-wrap text-sm text-base-content">{msg.content}</div>

            <%!-- Tool executions --%>
            <div :if={msg[:tool_executions] && msg.tool_executions != []} class="mt-2 space-y-1">
              <div
                :for={exec <- msg.tool_executions}
                class="text-xs text-base-content bg-base-100 rounded px-2 py-1"
              >
                <span class="font-medium">{exec.tool}</span>
                <span :if={match?({:ok, _}, exec.result)} class="text-success ml-1">ok</span>
                <span :if={match?({:error, _}, exec.result)} class="text-error ml-1">error</span>
              </div>
            </div>
          </div>

          <%!-- Loading indicator --%>
          <div :if={@chat_loading} class="flex items-center gap-2 text-base-content/50">
            <span class="loading loading-dots loading-sm"></span>
            <span class="text-sm">Thinking...</span>
          </div>

          <%!-- Transcribing indicator --%>
          <div :if={@is_transcribing} class="flex items-center gap-2 text-base-content/50">
            <span class="loading loading-dots loading-sm"></span>
            <span class="text-sm">Transcribing...</span>
          </div>
        </div>

        <%!-- Error display --%>
        <div :if={@chat_error} class="px-3 py-2 bg-error/10 text-error text-sm">
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
              placeholder={
                if @api_key, do: "Ask me to manage your todos...", else: "Configure API key first"
              }
              disabled={!@api_key || @chat_loading || @is_transcribing}
              class="flex-1 min-w-0 px-3 py-2 text-sm bg-base-300 border border-base-100 text-base-content placeholder:text-base-content/40 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary disabled:opacity-50"
              autocomplete="off"
            />
            <%!-- Voice record button --%>
            <button
              type="button"
              id="voice-record-btn"
              phx-hook="AudioRecorder"
              disabled={!@api_key || !@groq_api_key || @chat_loading || @is_transcribing}
              title={
                cond do
                  !@groq_api_key -> "Configure Groq API key for voice"
                  @is_recording -> "Click to stop recording"
                  true -> "Click to start voice recording"
                end
              }
              class={[
                "flex-shrink-0 px-3 py-2 text-sm rounded-lg transition-colors",
                "disabled:opacity-50 disabled:cursor-not-allowed",
                @is_recording && "bg-error text-error-content animate-pulse",
                !@is_recording && "bg-base-300 text-base-content hover:bg-base-100"
              ]}
            >
              <.icon
                name={if @is_recording, do: "hero-stop", else: "hero-microphone"}
                class="w-5 h-5"
              />
            </button>
            <button
              type="submit"
              disabled={!@api_key || @chat_loading || @is_transcribing || @chat_input == ""}
              title="Send message"
              class="flex-shrink-0 px-3 py-2 bg-primary text-primary-content text-sm rounded-lg hover:bg-primary/80 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <.icon name="hero-paper-airplane" class="w-5 h-5" />
            </button>
          </div>
        </form>
      </div>

      <%!-- Effect Log Modal --%>
      <.modal id="log-modal" class="w-full max-w-4xl">
        <:title>Effect Log</:title>
        <p class="text-sm text-base-content/60 mb-4">
          Skuld EffectLogger captures all effects during execution. The log is pruned
          after each loop iteration to stay bounded.
        </p>

        <%!-- Tabs --%>
        <div class="tabs tabs-bordered mb-4">
          <button
            phx-click="log_tab"
            phx-value-tab="inspect"
            class={["tab", @log_tab == :inspect && "tab-active"]}
          >
            Inspect
          </button>
          <button
            phx-click="log_tab"
            phx-value-tab="json"
            class={["tab", @log_tab == :json && "tab-active"]}
          >
            JSON (Cold Resume)
          </button>
        </div>

        <%!-- Tab Content - use hidden class instead of :if to avoid DOM changes --%>
        <div class="bg-gray-900 text-green-400 p-4 rounded-lg overflow-auto max-h-[60vh] font-mono text-xs">
          <pre class={@log_tab != :inspect && "hidden"}>{@log_inspect || "nil"}</pre>
          <pre class={@log_tab != :json && "hidden"}>{@log_json || "null"}</pre>
        </div>
      </.modal>

      <%!-- API Key Settings Modal --%>
      <.modal id="api-key-modal">
        <:title>API Key Settings</:title>

        <p class="text-sm text-base-content/60 mb-4">
          Configure your API keys to enable AI features.
          Keys are stored in your browser session and never sent to our servers.
        </p>

        <form action={~p"/settings/api-key"} method="post" class="space-y-4">
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <div>
            <label for="api_key" class="block text-sm font-medium text-base-content mb-1">
              Anthropic API Key <span class="text-base-content/40 font-normal">(Claude)</span>
            </label>
            <input
              type="password"
              name="api_key"
              id="api_key"
              placeholder="sk-ant-..."
              class="w-full px-3 py-2 bg-base-200 border border-base-300 text-base-content placeholder:text-base-content/40 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary"
              autocomplete="off"
            />
            <p :if={@api_key_source == :env} class="text-xs text-base-content/50 mt-1">
              Using key from ANTHROPIC_API_KEY env var
            </p>
          </div>

          <div>
            <label for="gemini_api_key" class="block text-sm font-medium text-base-content mb-1">
              Google AI API Key <span class="text-base-content/40 font-normal">(Gemini - free tier)</span>
            </label>
            <input
              type="password"
              name="gemini_api_key"
              id="gemini_api_key"
              placeholder="AIza..."
              class="w-full px-3 py-2 bg-base-200 border border-base-300 text-base-content placeholder:text-base-content/40 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary"
              autocomplete="off"
            />
            <p :if={@gemini_api_key && !@api_key_source} class="text-xs text-base-content/50 mt-1">
              Using key from GEMINI_API_KEY env var
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              <a
                href="https://aistudio.google.com/app/apikey"
                target="_blank"
                class="text-primary hover:underline"
              >
                Get a free Google AI API key
              </a>
            </p>
          </div>

          <div>
            <label for="groq_api_key" class="block text-sm font-medium text-base-content mb-1">
              Groq API Key <span class="text-base-content/40 font-normal">(for voice, optional)</span>
            </label>
            <input
              type="password"
              name="groq_api_key"
              id="groq_api_key"
              placeholder="gsk_..."
              class="w-full px-3 py-2 bg-base-200 border border-base-300 text-base-content placeholder:text-base-content/40 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary"
              autocomplete="off"
            />
            <p :if={@groq_api_key && !@api_key_source} class="text-xs text-base-content/50 mt-1">
              Using key from GROQ_API_KEY env var
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              <a
                href="https://console.groq.com/keys"
                target="_blank"
                class="text-primary hover:underline"
              >
                Create a free Groq API key
              </a>
            </p>
          </div>

          <div class="flex gap-2">
            <button
              type="submit"
              class="flex-1 px-4 py-2 bg-primary text-primary-content rounded-lg hover:bg-primary/80"
            >
              Save
            </button>
          </div>
        </form>

        <div :if={@api_key && @api_key_source == :session} class="mt-4 pt-4 border-t border-base-300">
          <form action={~p"/settings/api-key"} method="post">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="_method" value="delete" />
            <button
              type="submit"
              class="text-sm text-error hover:underline"
            >
              Clear saved API keys
            </button>
          </form>
        </div>
      </.modal>
    </div>
    """
  end

  defp message_class(:user), do: "bg-primary/10 rounded-lg p-3 ml-4"
  defp message_class(:assistant), do: "bg-base-300 rounded-lg p-3 mr-4"
  defp message_class(_), do: "bg-base-300 rounded-lg p-3"

  defp provider_display_name(:claude), do: "Anthropic"
  defp provider_display_name(:gemini), do: "Gemini"
  defp provider_display_name(:groq), do: "Groq"
  defp provider_display_name(_), do: "API"
end
