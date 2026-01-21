defmodule TodosMcp.Llm.AsyncConversationRunner do
  @moduledoc """
  Manages an LLM conversation via AsyncRunner.

  Provides functions to start, resume, and cancel conversations, plus
  `handle_info/3` to process yield messages from the conversation computation.

  ## Usage in LiveView

      # In mount
      {llm_runner, log} = AsyncConversationRunner.start(api_key: key, provider: :claude)
      assign(socket, llm_runner: llm_runner, log: log)

      # Send a message
      AsyncConversationRunner.resume(socket.assigns.llm_runner, message)

      # Handle all :llm messages with a single clause
      def handle_info({:llm, _, _} = msg, socket) do
        AsyncConversationRunner.handle_info(msg, socket,
          get_runner: fn s -> s.assigns.chat.llm_runner end,
          get_cmd_runner: fn s -> s.assigns.cmd_runner end,
          update_chat: fn s, updates -> update_chat(s, updates) end,
          on_tool_execution: fn s -> reload_todos(s) end
        )
      end
  """

  alias Skuld.AsyncRunner
  alias Skuld.Effects.EffectLogger
  alias TodosMcp.Llm.ConversationComp
  alias TodosMcp.Mcp.Tools
  alias TodosMcp.Run

  @doc """
  Start a new conversation.

  Returns `{llm_runner, log}` or `{nil, nil}` if api_key is nil.

  ## Options

  - `:api_key` - Required. API key for the LLM provider.
  - `:provider` - LLM provider (`:claude`, `:gemini`, `:groq`). Default: `:claude`.
  """
  @spec start(keyword()) :: {AsyncRunner.t() | nil, EffectLogger.Log.t() | nil}
  def start(opts) do
    api_key = Keyword.get(opts, :api_key)
    provider = Keyword.get(opts, :provider, :claude)

    if api_key do
      comp = ConversationComp.build(api_key: api_key, provider: provider)

      case AsyncRunner.start_sync(comp, tag: :llm, link: false) do
        {:ok, llm_runner, {:yield, :await_user_input, data}} ->
          {llm_runner, extract_log(data)}

        {:ok, _runner, _other} ->
          {nil, nil}

        {:error, _reason} ->
          {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  @doc """
  Resume the conversation with a value (user message, tool results, etc).

  This is async - responses come via handle_info.
  """
  @spec resume(AsyncRunner.t() | nil, term()) :: :ok
  def resume(nil, _value), do: :ok
  def resume(llm_runner, value), do: AsyncRunner.resume(llm_runner, value)

  @doc """
  Cancel the conversation runner.
  """
  @spec cancel(AsyncRunner.t() | nil) :: :ok
  def cancel(nil), do: :ok
  def cancel(llm_runner), do: AsyncRunner.cancel(llm_runner)

  @doc """
  Handle :llm messages from the conversation AsyncRunner.

  ## Callbacks (in opts)

  - `:get_runner` - `(socket) -> AsyncRunner.t() | nil` - get the llm_runner from socket
  - `:get_cmd_runner` - `(socket) -> AsyncRunner.t() | nil` - get the cmd_runner for tool execution
  - `:update_chat` - `(socket, (chat -> chat)) -> socket` - update chat state with a transform function
  - `:on_tool_execution` - `(socket) -> socket` - called after tools are executed (e.g., reload data)

  ## Returns

  `{:noreply, socket}` - suitable for returning directly from LiveView handle_info.
  """
  @spec handle_info(tuple(), Phoenix.LiveView.Socket.t(), keyword()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(msg, socket, opts) do
    get_runner = Keyword.fetch!(opts, :get_runner)
    get_cmd_runner = Keyword.fetch!(opts, :get_cmd_runner)
    update_chat = Keyword.fetch!(opts, :update_chat)
    on_tool_execution = Keyword.get(opts, :on_tool_execution, fn s -> s end)

    case msg do
      # Ready for next user input
      {:llm, :yield, :await_user_input, data} ->
        log = extract_log(data)
        {:noreply, update_chat.(socket, fn c -> %{c | log: log, loading: false} end)}

      # Execute tools and resume
      {:llm, :yield, %{type: :execute_tools, tool_uses: tool_requests}, _data} ->
        cmd_runner = get_cmd_runner.(socket)
        results = execute_tools(tool_requests, cmd_runner)
        resume(get_runner.(socket), results)
        {:noreply, socket}

      # Assistant response - show it and resume
      {:llm, :yield, %{type: :response, text: text, tool_executions: tool_executions}, data} ->
        log = extract_log(data)

        assistant_msg = %{
          role: :assistant,
          content: text,
          tool_executions: tool_executions
        }

        socket =
          if tool_executions != [] do
            on_tool_execution.(socket)
          else
            socket
          end

        socket =
          update_chat.(socket, fn c ->
            %{c | log: log, messages: c.messages ++ [assistant_msg]}
          end)

        # Resume to get back to await_user_input
        resume(get_runner.(socket), :ok)

        {:noreply, socket}

      # Error - show it and resume
      {:llm, :yield, %{type: :error, reason: reason}, data} ->
        log = extract_log(data)

        socket =
          update_chat.(socket, fn c ->
            %{c | log: log, loading: false, error: format_error(reason)}
          end)

        resume(get_runner.(socket), :ok)
        {:noreply, socket}

      # Throw - unrecoverable error
      {:llm, :throw, error} ->
        {:noreply,
         update_chat.(socket, fn c -> %{c | loading: false, error: format_error(error)} end)}

      # Result - conversation ended (shouldn't happen)
      {:llm, :result, _value} ->
        {:noreply,
         update_chat.(socket, fn c ->
           %{c | loading: false, error: "Conversation ended unexpectedly"}
         end)}

      # Stopped - runner was cancelled
      {:llm, :stopped, _reason} ->
        {:noreply, socket}
    end
  end

  @doc """
  Get the log formatted for inspect display.
  """
  @spec format_log_inspect(EffectLogger.Log.t() | nil) :: String.t()
  def format_log_inspect(nil), do: "nil"

  def format_log_inspect(log) do
    log
    |> EffectLogger.Log.finalize()
    |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  @doc """
  Get the log formatted as JSON.
  """
  @spec format_log_json(EffectLogger.Log.t() | nil) :: String.t()
  def format_log_json(nil), do: "null"

  def format_log_json(log) do
    try do
      log
      |> EffectLogger.Log.finalize()
      |> Jason.encode!(pretty: true)
    rescue
      e ->
        Jason.encode!(
          %{error: "Failed to serialize log to JSON", message: Exception.message(e)},
          pretty: true
        )
    end
  end

  # Private helpers

  defp extract_log(nil), do: nil
  defp extract_log(data) when is_map(data), do: Map.get(data, EffectLogger)
  defp extract_log(_), do: nil

  defp execute_tools(tool_requests, cmd_runner) do
    Enum.map(tool_requests, &execute_single_tool(&1, cmd_runner))
  end

  defp execute_single_tool(%{name: name, input: input}, cmd_runner) do
    case Tools.find_module(name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      module ->
        try do
          operation = module.from_json(input)
          execute_operation(operation, cmd_runner)
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  defp execute_operation(operation, nil) do
    Run.execute(operation)
  end

  defp execute_operation(operation, cmd_runner) do
    case AsyncRunner.resume_sync(cmd_runner, operation) do
      {:yield, result, _data} -> result
      {:throw, error} -> {:error, error}
      {:error, :timeout} -> {:error, :timeout}
      other -> {:error, {:unexpected_response, other}}
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
end
