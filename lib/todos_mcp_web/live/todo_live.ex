defmodule TodosMcpWeb.TodoLive do
  @moduledoc """
  LiveView for the todo list interface with LLM chat sidebar.

  All actions dispatch through TodosMcp.Run which handles the
  Skuld effect handler stack.

  ## State Structure

  Uses typed structs for state management (see `TodoLive.State`):
  - `@todos` - Todo list, stats, filter, form input
  - `@api_keys` - API key configuration and provider selection
  - `@chat` - Conversation state, messages, voice recording
  - `@log_modal` - Effect log modal state
  - `@tenant_id` - Tenant identifier (string)
  - `@sidebar_open` - Sidebar visibility (boolean)
  """
  use TodosMcpWeb, :live_view

  alias TodosMcp.Run
  alias TodosMcp.Llm.ConversationRunner
  alias TodosMcp.Todos.Commands.{CreateTodo, ToggleTodo, DeleteTodo, ClearCompleted, CompleteAll}
  alias TodosMcp.Todos.Queries.{ListTodos, GetStats}
  alias TodosMcp.Effects.Transcribe
  alias TodosMcp.Effects.Transcribe.GroqHandler

  alias __MODULE__.State
  alias State.{TodosState, ApiKeysState, ChatState, LogModalState}

  # Allowed audio formats for voice recording (ensures atoms exist for to_existing_atom)
  @allowed_audio_formats [:webm, :mp3, :wav, :ogg]

  # ============================================================================
  # Typed Update Helpers
  # ============================================================================

  @spec update_todos(Phoenix.LiveView.Socket.t(), (TodosState.t() -> TodosState.t())) ::
          Phoenix.LiveView.Socket.t()
  defp update_todos(socket, fun) do
    assign(socket, todos: fun.(socket.assigns.todos))
  end

  @spec update_api_keys(Phoenix.LiveView.Socket.t(), (ApiKeysState.t() -> ApiKeysState.t())) ::
          Phoenix.LiveView.Socket.t()
  defp update_api_keys(socket, fun) do
    assign(socket, api_keys: fun.(socket.assigns.api_keys))
  end

  @spec update_chat(Phoenix.LiveView.Socket.t(), (ChatState.t() -> ChatState.t())) ::
          Phoenix.LiveView.Socket.t()
  defp update_chat(socket, fun) do
    assign(socket, chat: fun.(socket.assigns.chat))
  end

  @spec update_log_modal(Phoenix.LiveView.Socket.t(), (LogModalState.t() -> LogModalState.t())) ::
          Phoenix.LiveView.Socket.t()
  defp update_log_modal(socket, fun) do
    assign(socket, log_modal: fun.(socket.assigns.log_modal))
  end

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(_params, session, socket) do
    tenant_id = session["tenant_id"] || "default"

    {:ok, todo_items} = Run.execute(%ListTodos{}, tenant_id: tenant_id)
    {:ok, stats} = Run.execute(%GetStats{}, tenant_id: tenant_id)

    # Build API keys state
    api_keys = build_api_keys(session)
    current_key = ApiKeysState.current_key(api_keys)

    # Initialize conversation runner
    runner = start_runner_with_key(current_key, api_keys.selected_provider, tenant_id)

    {:ok,
     assign(socket,
       tenant_id: tenant_id,
       sidebar_open: true,
       todos: %TodosState{items: todo_items, stats: stats},
       api_keys: api_keys,
       chat: %ChatState{runner: runner},
       log_modal: %LogModalState{}
     )}
  end

  defp build_api_keys(session) do
    # Anthropic (Claude)
    session_api_key = session["api_key"]
    env_api_key = System.get_env("ANTHROPIC_API_KEY")
    anthropic = session_api_key || env_api_key

    source =
      cond do
        session_api_key -> :session
        env_api_key -> :env
        true -> nil
      end

    # Gemini
    gemini = session["gemini_api_key"] || System.get_env("GEMINI_API_KEY")

    # Groq
    groq = session["groq_api_key"] || System.get_env("GROQ_API_KEY")

    # Determine selected provider
    saved_provider = session["selected_provider"]

    selected_provider =
      case saved_provider do
        "groq" when groq != nil ->
          :groq

        "gemini" when gemini != nil ->
          :gemini

        "claude" when anthropic != nil ->
          :claude

        _ ->
          cond do
            anthropic -> :claude
            groq -> :groq
            gemini -> :gemini
            true -> :claude
          end
      end

    %ApiKeysState{
      anthropic: anthropic,
      gemini: gemini,
      groq: groq,
      source: source,
      selected_provider: selected_provider
    }
  end

  defp start_runner_with_key(nil, _provider, _tenant_id), do: nil

  defp start_runner_with_key(api_key, provider, tenant_id) do
    case ConversationRunner.start(api_key: api_key, provider: provider, tenant_id: tenant_id) do
      {:ok, runner} -> runner
      {:error, _reason} -> nil
    end
  end

  # ============================================================================
  # Handle Events - Chat
  # ============================================================================

  @impl true
  def handle_event("chat_send", %{"message" => message}, socket) when message != "" do
    chat = socket.assigns.chat

    if chat.runner do
      user_msg = %{role: :user, content: message}

      socket =
        update_chat(socket, fn c ->
          %{c | messages: c.messages ++ [user_msg], input: "", loading: true, error: nil}
        end)

      runner = socket.assigns.chat.runner
      pid = self()

      Task.start(fn ->
        result = ConversationRunner.send_message(runner, message)
        send(pid, {:llm_response, result})
      end)

      {:noreply, socket}
    else
      {:noreply, update_chat(socket, fn c -> %{c | error: "API key not configured"} end)}
    end
  end

  def handle_event("chat_send", _params, socket), do: {:noreply, socket}

  def handle_event("chat_input", %{"message" => message}, socket) do
    {:noreply, update_chat(socket, fn c -> %{c | input: message} end)}
  end

  def handle_event("chat_clear", _params, socket) do
    api_keys = socket.assigns.api_keys
    current_key = ApiKeysState.current_key(api_keys)

    runner =
      start_runner_with_key(current_key, api_keys.selected_provider, socket.assigns.tenant_id)

    {:noreply, update_chat(socket, fn c -> %{c | runner: runner, messages: [], error: nil} end)}
  end

  def handle_event("change_provider", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)
    api_keys = socket.assigns.api_keys
    new_key = ApiKeysState.key_for(api_keys, provider)
    runner = start_runner_with_key(new_key, provider, socket.assigns.tenant_id)

    socket =
      socket
      |> update_api_keys(fn k -> %{k | selected_provider: provider} end)
      |> update_chat(fn c -> %{c | runner: runner, messages: [], error: nil} end)
      |> push_event("save_provider", %{provider: Atom.to_string(provider)})

    {:noreply, socket}
  end

  # ============================================================================
  # Handle Events - Log Modal
  # ============================================================================

  def handle_event("show_log", _params, socket) do
    {log_inspect, log_json} =
      case socket.assigns.chat.runner do
        nil ->
          {"no runner", "null"}

        runner ->
          {
            ConversationRunner.get_log_inspect(runner),
            ConversationRunner.get_log_json(runner)
          }
      end

    {:noreply, update_log_modal(socket, fn l -> %{l | inspect: log_inspect, json: log_json} end)}
  end

  def handle_event("log_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)
    {:noreply, update_log_modal(socket, fn l -> %{l | tab: tab} end)}
  end

  # ============================================================================
  # Handle Events - Voice Recording
  # ============================================================================

  def handle_event("recording_started", _params, socket) do
    {:noreply, update_chat(socket, fn c -> %{c | is_recording: true, error: nil} end)}
  end

  def handle_event("recording_error", %{"error" => error}, socket) do
    {:noreply,
     update_chat(socket, fn c ->
       %{c | is_recording: false, error: "Microphone error: #{error}"}
     end)}
  end

  def handle_event("audio_recorded", %{"audio" => base64_audio, "format" => format}, socket) do
    socket = update_chat(socket, fn c -> %{c | is_recording: false, is_transcribing: true} end)
    groq_key = socket.assigns.api_keys.groq

    if groq_key do
      audio_data = Base.decode64!(base64_audio)
      format_atom = String.to_existing_atom(format)

      if format_atom in @allowed_audio_formats do
        pid = self()

        Task.start(fn ->
          result = transcribe_audio(audio_data, format_atom, groq_key)
          send(pid, {:transcription_result, result})
        end)

        {:noreply, socket}
      else
        {:noreply,
         update_chat(socket, fn c ->
           %{c | is_transcribing: false, error: "Unsupported audio format: #{format}"}
         end)}
      end
    else
      {:noreply,
       update_chat(socket, fn c ->
         %{c | is_transcribing: false, error: "Groq API key not configured for voice input"}
       end)}
    end
  end

  # ============================================================================
  # Handle Events - UI
  # ============================================================================

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  # ============================================================================
  # Handle Events - Todos
  # ============================================================================

  def handle_event("create", %{"title" => title}, socket) when title != "" do
    case run_cmd(socket, %CreateTodo{title: title}) do
      {:ok, _todo} ->
        socket =
          socket
          |> update_todos(fn t -> %{t | new_title: ""} end)
          |> reload_todos()

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create todo")}
    end
  end

  def handle_event("create", _params, socket), do: {:noreply, socket}

  def handle_event("toggle", %{"id" => id}, socket) do
    case run_cmd(socket, %ToggleTodo{id: id}) do
      {:ok, _todo} -> {:noreply, reload_todos(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to toggle todo")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case run_cmd(socket, %DeleteTodo{id: id}) do
      {:ok, _todo} -> {:noreply, reload_todos(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to delete todo")}
    end
  end

  def handle_event("clear_completed", _params, socket) do
    case run_cmd(socket, %ClearCompleted{}) do
      {:ok, _result} -> {:noreply, reload_todos(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to clear completed")}
    end
  end

  def handle_event("complete_all", _params, socket) do
    case run_cmd(socket, %CompleteAll{}) do
      {:ok, _result} -> {:noreply, reload_todos(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to complete all")}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    filter_atom = String.to_existing_atom(filter)
    {:ok, items} = run_cmd(socket, %ListTodos{filter: filter_atom})

    {:noreply, update_todos(socket, fn t -> %{t | items: items, filter: filter_atom} end)}
  end

  def handle_event("update_new_title", %{"title" => title}, socket) do
    {:noreply, update_todos(socket, fn t -> %{t | new_title: title} end)}
  end

  # ============================================================================
  # Handle Info
  # ============================================================================

  @impl true
  def handle_info({:llm_response, result}, socket) do
    socket =
      case result do
        {:ok, response, updated_runner} ->
          assistant_msg = %{
            role: :assistant,
            content: response.text,
            tool_executions: response.tool_executions
          }

          socket =
            if response.tool_executions != [] do
              reload_todos(socket)
            else
              socket
            end

          update_chat(socket, fn c ->
            %{c | runner: updated_runner, messages: c.messages ++ [assistant_msg], loading: false}
          end)

        {:error, reason, updated_runner} ->
          update_chat(socket, fn c ->
            %{c | runner: updated_runner, loading: false, error: format_error(reason)}
          end)
      end

    {:noreply, socket}
  end

  def handle_info({:transcription_result, result}, socket) do
    socket = update_chat(socket, fn c -> %{c | is_transcribing: false} end)

    case result do
      {:ok, %{text: text}} when text != "" ->
        chat = socket.assigns.chat

        if chat.runner do
          user_msg = %{role: :user, content: text}

          socket =
            update_chat(socket, fn c ->
              %{c | messages: c.messages ++ [user_msg], input: "", loading: true, error: nil}
            end)

          runner = socket.assigns.chat.runner
          pid = self()

          Task.start(fn ->
            result = ConversationRunner.send_message(runner, text)
            send(pid, {:llm_response, result})
          end)

          {:noreply, socket}
        else
          {:noreply, update_chat(socket, fn c -> %{c | error: "API key not configured"} end)}
        end

      {:ok, %{text: ""}} ->
        {:noreply, update_chat(socket, fn c -> %{c | error: "No speech detected"} end)}

      {:error, reason} ->
        {:noreply,
         update_chat(socket, fn c -> %{c | error: format_transcription_error(reason)} end)}

      _other ->
        {:noreply,
         update_chat(socket, fn c -> %{c | error: "Transcription failed: unexpected error"} end)}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp reload_todos(socket) do
    filter = socket.assigns.todos.filter
    {:ok, items} = run_cmd(socket, %ListTodos{filter: filter})
    {:ok, stats} = run_cmd(socket, %GetStats{})

    update_todos(socket, fn t -> %{t | items: items, stats: stats} end)
  end

  defp run_cmd(socket, operation) do
    Run.execute(operation, tenant_id: socket.assigns.tenant_id)
  end

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

  defp format_error({:api_error, status, body}) when is_binary(body) do
    "API error (#{status}): #{body}"
  end

  defp format_error({:api_error, status, body}) when is_map(body) do
    "API error (#{status}): #{inspect(body["error"]["message"] || body)}"
  end

  defp format_error({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  defp format_error(:max_iterations_exceeded), do: "Too many tool calls. Please try again."
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  defp format_transcription_error({:api_error, status, body}) when is_binary(body) do
    "Transcription error (#{status}): #{body}"
  end

  defp format_transcription_error({:api_error, status, body}) when is_map(body) do
    "Transcription error (#{status}): #{inspect(body["error"]["message"] || body)}"
  end

  defp format_transcription_error({:request_failed, reason}) do
    "Transcription failed: #{inspect(reason)}"
  end

  defp format_transcription_error(reason), do: "Transcription error: #{inspect(reason)}"

  # ============================================================================
  # Render
  # ============================================================================

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
                value={@todos.new_title}
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
              {@todos.stats.active} active, {@todos.stats.completed} completed
            </span>
            <div class="flex gap-2">
              <button
                :if={@todos.stats.active > 0}
                phx-click="complete_all"
                class="text-primary hover:underline"
              >
                Complete all
              </button>
              <button
                :if={@todos.stats.completed > 0}
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
                @todos.filter == filter && "border-b-2 border-primary text-primary",
                @todos.filter != filter && "text-base-content/50 hover:text-base-content/80"
              ]}
            >
              {String.capitalize(to_string(filter))}
            </button>
          </div>

          <%!-- Todo list --%>
          <ul class="space-y-2">
            <li
              :for={todo <- @todos.items}
              class="flex items-center gap-3 p-3 bg-base-200 rounded-lg group"
            >
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
                <p
                  :if={todo.description not in [nil, ""]}
                  class={["text-sm mt-0.5 opacity-70", todo.completed && "line-through opacity-40"]}
                >
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

          <p :if={@todos.items == []} class="text-center text-base-content/40 py-8">
            <%= case @todos.filter do %>
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
      <.chat_sidebar
        :if={@sidebar_open}
        chat={@chat}
        api_keys={@api_keys}
        log_modal={@log_modal}
      />

      <%!-- Effect Log Modal --%>
      <.log_modal log_modal={@log_modal} />

      <%!-- API Key Settings Modal --%>
      <.api_key_modal api_keys={@api_keys} />
    </div>
    """
  end

  # ============================================================================
  # Component: Chat Sidebar
  # ============================================================================

  defp chat_sidebar(assigns) do
    current_key = ApiKeysState.current_key(assigns.api_keys)
    assigns = assign(assigns, current_key: current_key)

    ~H"""
    <div class="fixed right-0 top-[64px] bottom-0 w-80 flex flex-col bg-base-200 border-l border-base-300">
      <%!-- Header --%>
      <div class="flex items-center justify-between p-3 border-b border-base-300">
        <div class="flex items-center gap-2">
          <h2 class="font-semibold text-base-content">AI</h2>
          <form phx-change="change_provider">
            <select
              id="provider-select"
              phx-hook="ProviderSelector"
              name="provider"
              data-selected={Atom.to_string(@api_keys.selected_provider)}
              class="select select-xs bg-base-300 border-base-100 text-base-content min-h-0 h-7 pl-2 pr-6"
            >
              <%= Phoenix.HTML.Form.options_for_select(
                [
                  {"Claude #{if @api_keys.anthropic, do: "", else: "(no key)"}", "claude"},
                  {"Groq #{if @api_keys.groq, do: "", else: "(no key)"}", "groq"},
                  {"Gemini #{if @api_keys.gemini, do: "", else: "(no key)"}", "gemini"}
                ],
                Atom.to_string(@api_keys.selected_provider)
              ) %>
            </select>
          </form>
        </div>
        <div class="flex items-center gap-2">
          <button
            :if={@chat.runner}
            phx-click={JS.push("show_log") |> show_modal("log-modal")}
            class="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium text-accent bg-accent/10 rounded-md hover:bg-accent/20 transition-colors"
            title="View effect log"
          >
            <.icon name="hero-code-bracket" class="w-3.5 h-3.5" />
            <span>Log</span>
          </button>
          <button
            :if={@chat.messages != []}
            phx-click="chat_clear"
            class="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium text-base-content/70 bg-base-300 rounded-md hover:bg-base-100 transition-colors"
          >
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            <span>Clear</span>
          </button>
        </div>
      </div>

      <%!-- API Key Status --%>
      <div :if={!@current_key} class="p-4 bg-warning/10 text-warning text-sm">
        <p class="font-medium">API Key Required</p>
        <p class="mt-1 text-warning/80">
          Configure your {provider_display_name(@api_keys.selected_provider)} API key to enable chat.
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
        :if={@current_key}
        class="px-3 py-2 text-xs text-base-content/50 border-b border-base-300 flex items-center justify-between"
      >
        <span>
          API Key: {if @api_keys.source == :session, do: "configured", else: "from env"}
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
        <div :for={msg <- @chat.messages} class={message_class(msg.role)}>
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
        <div :if={@chat.loading} class="flex items-center gap-2 text-base-content/50">
          <span class="loading loading-dots loading-sm"></span>
          <span class="text-sm">Thinking...</span>
        </div>

        <%!-- Transcribing indicator --%>
        <div :if={@chat.is_transcribing} class="flex items-center gap-2 text-base-content/50">
          <span class="loading loading-dots loading-sm"></span>
          <span class="text-sm">Transcribing...</span>
        </div>
      </div>

      <%!-- Error display --%>
      <div :if={@chat.error} class="px-3 py-2 bg-error/10 text-error text-sm">
        {@chat.error}
      </div>

      <%!-- Input form --%>
      <form phx-submit="chat_send" class="p-3 border-t border-base-300">
        <div class="flex gap-2">
          <input
            type="text"
            name="message"
            id="chat-input"
            value={@chat.input}
            phx-change="chat_input"
            phx-hook="MaintainFocus"
            placeholder={
              if @current_key, do: "Ask me to manage your todos...", else: "Configure API key first"
            }
            disabled={!@current_key || @chat.loading || @chat.is_transcribing}
            class="flex-1 min-w-0 px-3 py-2 text-sm bg-base-300 border border-base-100 text-base-content placeholder:text-base-content/40 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary disabled:opacity-50"
            autocomplete="off"
          />
          <%!-- Voice record button --%>
          <button
            type="button"
            id="voice-record-btn"
            phx-hook="AudioRecorder"
            disabled={!@current_key || !@api_keys.groq || @chat.loading || @chat.is_transcribing}
            title={
              cond do
                !@api_keys.groq -> "Configure Groq API key for voice"
                @chat.is_recording -> "Click to stop recording"
                true -> "Click to start voice recording"
              end
            }
            class={[
              "flex-shrink-0 px-3 py-2 text-sm rounded-lg transition-colors",
              "disabled:opacity-50 disabled:cursor-not-allowed",
              @chat.is_recording && "bg-error text-error-content animate-pulse",
              !@chat.is_recording && "bg-base-300 text-base-content hover:bg-base-100"
            ]}
          >
            <.icon
              name={if @chat.is_recording, do: "hero-stop", else: "hero-microphone"}
              class="w-5 h-5"
            />
          </button>
          <button
            type="submit"
            disabled={!@current_key || @chat.loading || @chat.is_transcribing || @chat.input == ""}
            title="Send message"
            class="flex-shrink-0 px-3 py-2 bg-primary text-primary-content text-sm rounded-lg hover:bg-primary/80 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <.icon name="hero-paper-airplane" class="w-5 h-5" />
          </button>
        </div>
      </form>
    </div>
    """
  end

  # ============================================================================
  # Component: Log Modal
  # ============================================================================

  defp log_modal(assigns) do
    ~H"""
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
          class={["tab", @log_modal.tab == :inspect && "tab-active"]}
        >
          Inspect
        </button>
        <button
          phx-click="log_tab"
          phx-value-tab="json"
          class={["tab", @log_modal.tab == :json && "tab-active"]}
        >
          JSON (Cold Resume)
        </button>
      </div>

      <%!-- Tab Content --%>
      <div class="bg-gray-900 text-green-400 p-4 rounded-lg overflow-auto max-h-[60vh] font-mono text-xs">
        <pre class={@log_modal.tab != :inspect && "hidden"}>{@log_modal.inspect || "nil"}</pre>
        <pre class={@log_modal.tab != :json && "hidden"}>{@log_modal.json || "null"}</pre>
      </div>
    </.modal>
    """
  end

  # ============================================================================
  # Component: API Key Modal
  # ============================================================================

  defp api_key_modal(assigns) do
    current_key = ApiKeysState.current_key(assigns.api_keys)
    assigns = assign(assigns, current_key: current_key)

    ~H"""
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
          <p :if={@api_keys.source == :env} class="text-xs text-base-content/50 mt-1">
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
          <p :if={@api_keys.gemini && !@api_keys.source} class="text-xs text-base-content/50 mt-1">
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
          <p :if={@api_keys.groq && !@api_keys.source} class="text-xs text-base-content/50 mt-1">
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

      <div
        :if={@current_key && @api_keys.source == :session}
        class="mt-4 pt-4 border-t border-base-300"
      >
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
    """
  end

  # ============================================================================
  # Helper Functions for Templates
  # ============================================================================

  defp message_class(:user), do: "bg-primary/10 rounded-lg p-3 ml-4"
  defp message_class(:assistant), do: "bg-base-300 rounded-lg p-3 mr-4"
  defp message_class(_), do: "bg-base-300 rounded-lg p-3"

  defp provider_display_name(:claude), do: "Anthropic"
  defp provider_display_name(:gemini), do: "Gemini"
  defp provider_display_name(:groq), do: "Groq"
  defp provider_display_name(_), do: "API"
end
