defmodule TodosMcp.Llm.ConversationRunner do
  @moduledoc """
  Orchestrates the conversation computation using AsyncRunner.

  This module is the "Run" equivalent for conversations - it:
  - Sets up the LlmCall handler with provider configuration
  - Uses AsyncRunner to manage the conversation process
  - Handles Yield effects at boundaries
  - Executes tools through the command processor when requested
  - Returns control to the caller for user input and responses

  ## Yield Protocol

  The conversation computation yields at these boundaries:

  | Yield Value | Handling |
  |-------------|----------|
  | `:await_user_input` | Return to caller, wait for `send_message/2` |
  | `{:execute_tools, requests}` | Execute via cmd_runner, resume automatically |
  | `{:response, text, executions}` | Return to caller, then resume |
  | `{:error, reason}` | Return to caller, then resume |

  ## Example

      alias TodosMcp.Llm.ConversationRunner

      # Start a new conversation
      {:ok, runner} = ConversationRunner.start(api_key: "sk-ant-...")

      # Send a message
      case ConversationRunner.send_message(runner, "Create a todo for groceries") do
        {:ok, response, updated_runner} ->
          IO.puts(response.text)
          # Continue with updated_runner

        {:error, reason, updated_runner} ->
          IO.puts("Error: \#{reason}")
      end
  """

  alias Skuld.AsyncRunner
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias TodosMcp.Llm.ConversationComp
  alias TodosMcp.Llm.Claude
  alias TodosMcp.Effects.LlmCall
  alias TodosMcp.Effects.LlmCall.ClaudeHandler
  alias TodosMcp.Effects.LlmCall.GeminiHandler
  alias TodosMcp.Effects.LlmCall.GroqHandler
  alias TodosMcp.Mcp.Tools

  @providers [:claude, :gemini, :groq]

  defstruct [:async_runner, :config, :log]

  @type t :: %__MODULE__{
          async_runner: AsyncRunner.t(),
          config: map(),
          log: EffectLogger.Log.t() | nil
        }

  @type response :: %{
          text: String.t(),
          tool_executions: [tool_execution()]
        }

  @type tool_execution :: %{
          tool: String.t(),
          id: String.t(),
          input: map(),
          result: {:ok, term()} | {:error, term()}
        }

  @doc """
  Return the list of supported providers.
  """
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc """
  Start a new conversation.

  ## Options

  - `:api_key` - Required. API key for the selected provider.
  - `:provider` - LLM provider (`:claude`, `:gemini`, or `:groq`). Default: `:claude`.
  - `:system` - System prompt (optional, has sensible default).
  - `:model` - Model to use (optional, provider-specific default).
  - `:tools` - Tool definitions (optional, defaults to all MCP tools).
  - `:tenant_id` - Tenant ID for tool execution (optional).
  - `:cmd_runner` - AsyncRunner for command execution (optional, uses Run.execute if not provided).

  Returns `{:ok, runner}` when ready for user input.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    provider = Keyword.get(opts, :provider, :claude)
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    cmd_runner = Keyword.get(opts, :cmd_runner)
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model)

    # Get tools in Claude format (GeminiHandler will convert as needed)
    tools =
      Keyword.get_lazy(opts, :tools, fn ->
        Tools.all() |> Claude.convert_tools()
      end)

    config = %{
      api_key: api_key,
      provider: provider,
      tenant_id: tenant_id,
      cmd_runner: cmd_runner,
      system: system,
      model: model,
      tools: tools
    }

    # Build config (constant - via Reader, not logged) and state (mutable - via State, logged)
    conversation_config =
      ConversationComp.initial_config(
        tools: tools,
        system: system || ConversationComp.default_system_prompt()
      )

    initial_state = ConversationComp.initial_state()

    # Build the computation with handlers
    # Reader is outside EffectLogger (config lookups not logged)
    # State is inside EffectLogger (state changes are logged for cold resume)
    # EffectLogger decorates suspends with the log via suspend.data
    comp =
      ConversationComp.run()
      |> State.with_handler(initial_state, tag: ConversationComp)
      |> EffectLogger.with_logging(state_keys: [State.state_key(ConversationComp)])
      |> Reader.with_handler(conversation_config, tag: ConversationComp)
      |> LlmCall.with_handler(llm_handler(config))

    # Start with AsyncRunner - it adds Yield and Throw handlers
    case AsyncRunner.start_sync(comp, tag: :llm, link: false) do
      {:ok, async_runner, {:yield, :await_user_input, data}} ->
        log = extract_log(data)
        {:ok, %__MODULE__{async_runner: async_runner, config: config, log: log}}

      {:ok, _async_runner, {:yield, other, _data}} ->
        {:error, {:unexpected_yield, other}}

      {:ok, _async_runner, {:throw, error}} ->
        {:error, error}

      {:ok, _async_runner, {:result, value}} ->
        {:error, {:unexpected_completion, value}}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  @doc """
  Send a user message and get the response.

  Resumes the conversation computation with the user message,
  handles tool execution internally, and returns when the
  assistant produces a response.

  Returns `{:ok, response, updated_runner}` or `{:error, reason, runner}`.
  """
  @spec send_message(t(), String.t()) ::
          {:ok, response(), t()} | {:error, term(), t()}
  def send_message(%__MODULE__{} = runner, message) do
    case AsyncRunner.resume_sync(runner.async_runner, message, timeout: 60_000) do
      {:yield, value, data} -> process_yield(value, data, runner)
      {:result, value} -> {:error, {:conversation_ended, value}, runner}
      {:throw, error} -> {:error, error, runner}
      {:error, :timeout} -> {:error, :timeout, runner}
    end
  end

  @doc """
  Get the current effect log.

  Returns the EffectLogger.Log struct capturing all effects executed so far.
  The log is pruned after each loop iteration to stay bounded.
  """
  @spec get_log(t()) :: EffectLogger.Log.t() | nil
  def get_log(%__MODULE__{log: log}), do: log

  @doc """
  Get the effect log as pretty-printed Elixir inspect output.

  Useful for displaying the log in the UI to show how the
  conversation state machine works. Handles all Elixir terms.
  """
  @spec get_log_inspect(t()) :: String.t()
  def get_log_inspect(%__MODULE__{log: nil}), do: "nil"

  def get_log_inspect(%__MODULE__{log: log}) do
    log
    |> EffectLogger.Log.finalize()
    |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  @doc """
  Get the effect log as JSON for cold resume.

  This is the serialized format that can be used for cold resume
  via `EffectLogger.with_resume/3`.
  """
  @spec get_log_json(t()) :: String.t()
  def get_log_json(%__MODULE__{log: nil}), do: "null"

  def get_log_json(%__MODULE__{log: log}) do
    try do
      log
      |> EffectLogger.Log.finalize()
      |> Jason.encode!(pretty: true)
    rescue
      e ->
        Jason.encode!(
          %{
            error: "Failed to serialize log to JSON",
            message: Exception.message(e)
          },
          pretty: true
        )
    end
  end

  # Process yields until we get a response or await_user_input
  defp process_yield(:await_user_input, data, runner) do
    # Shouldn't happen immediately after sending a message
    # but handle it gracefully by returning an empty response
    log = extract_log(data)
    {:ok, %{text: "", tool_executions: []}, %{runner | log: log}}
  end

  defp process_yield(%{type: :execute_tools, tool_uses: tool_requests}, _data, runner) do
    # Execute tools and continue
    results = execute_tools(tool_requests, runner.config.cmd_runner)

    case AsyncRunner.resume_sync(runner.async_runner, results, timeout: 60_000) do
      {:yield, value, data} -> process_yield(value, data, runner)
      {:result, value} -> {:error, {:conversation_ended, value}, runner}
      {:throw, error} -> {:error, error, runner}
      {:error, :timeout} -> {:error, :timeout, runner}
    end
  end

  defp process_yield(
         %{type: :response, text: text, tool_executions: tool_executions},
         data,
         runner
       ) do
    # Got a response - resume to get back to await_user_input, then return
    log = extract_log(data)

    case AsyncRunner.resume_sync(runner.async_runner, :ok, timeout: 5_000) do
      {:yield, :await_user_input, _data} ->
        response = %{text: text, tool_executions: tool_executions}
        {:ok, response, %{runner | log: log}}

      {:yield, other, _data} ->
        response = %{text: text, tool_executions: tool_executions}
        {:error, {:unexpected_yield_after_response, other, response}, %{runner | log: log}}

      {:result, value} ->
        {:error, {:unexpected_result_after_response, value}, %{runner | log: log}}

      {:throw, error} ->
        {:error, error, %{runner | log: log}}

      {:error, :timeout} ->
        {:error, :timeout, %{runner | log: log}}
    end
  end

  defp process_yield(%{type: :error, reason: reason}, data, runner) do
    # Error occurred - resume to continue, then return error
    log = extract_log(data)

    case AsyncRunner.resume_sync(runner.async_runner, :ok, timeout: 5_000) do
      {:yield, :await_user_input, _data} ->
        {:error, reason, %{runner | log: log}}

      _other ->
        {:error, reason, %{runner | log: log}}
    end
  end

  # Extract log from suspend data (EffectLogger stores it under its module key)
  defp extract_log(nil), do: nil
  defp extract_log(data) when is_map(data), do: Map.get(data, EffectLogger)
  defp extract_log(_), do: nil

  # Execute tool requests through the command processor (or Run.execute as fallback)
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

  # Execute via cmd_runner if available, otherwise fall back to Run.execute
  defp execute_operation(operation, nil) do
    # No cmd_runner provided, use Run.execute directly
    TodosMcp.Run.execute(operation)
  end

  defp execute_operation(operation, cmd_runner) do
    # Use the cmd_runner via resume_sync - response comes back to this process
    case AsyncRunner.resume_sync(cmd_runner, operation) do
      {:yield, result, _data} -> result
      {:throw, error} -> {:error, error}
      {:error, :timeout} -> {:error, :timeout}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  # Build the LlmCall handler with config
  defp llm_handler(config) do
    base_opts =
      [api_key: config.api_key]
      |> maybe_add(:system, config.system)
      |> maybe_add(:model, config.model)
      |> maybe_add(:tools, config.tools)

    case config.provider do
      :gemini -> GeminiHandler.handler(base_opts)
      :groq -> GroqHandler.handler(base_opts)
      _claude -> ClaudeHandler.handler(base_opts)
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
