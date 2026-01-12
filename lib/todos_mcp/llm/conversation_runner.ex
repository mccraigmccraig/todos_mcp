defmodule TodosMcp.Llm.ConversationRunner do
  @moduledoc """
  Orchestrates the conversation computation, handling Yield boundaries.

  This module is the "Run" equivalent for conversations - it:
  - Sets up the LlmCall handler with Claude configuration
  - Handles Yield effects at boundaries
  - Executes tools through the domain stack when requested
  - Returns control to the caller for user input and responses

  ## Yield Protocol

  The conversation computation yields at these boundaries:

  | Yield Value | Handling |
  |-------------|----------|
  | `:await_user_input` | Return to caller, wait for `send_message/2` |
  | `{:execute_tools, requests}` | Execute via Run, resume automatically |
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

  alias Skuld.Comp
  alias Skuld.Comp.Suspend
  alias Skuld.Effects.{EffectLogger, Reader, State, Yield, Throw}
  alias TodosMcp.Llm.{ConversationComp, Claude}
  alias TodosMcp.Effects.LlmCall
  alias TodosMcp.Effects.LlmCall.{ClaudeHandler, GeminiHandler, GroqHandler}
  alias TodosMcp.Mcp.Tools
  alias TodosMcp.Run

  @providers [:claude, :gemini, :groq]

  defstruct [:resume_fn, :config, :log]

  @type t :: %__MODULE__{
          resume_fn: (term() -> {term(), Skuld.Comp.Types.env()}),
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
  - `:provider` - LLM provider (`:claude` or `:gemini`). Default: `:claude`.
  - `:system` - System prompt (optional, has sensible default).
  - `:model` - Model to use (optional, provider-specific default).
  - `:tools` - Tool definitions (optional, defaults to all MCP tools).
  - `:tenant_id` - Tenant ID for tool execution (optional).

  Returns `{:ok, runner}` when ready for user input.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    provider = Keyword.get(opts, :provider, :claude)
    tenant_id = Keyword.get(opts, :tenant_id, "default")
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
    # Only capture State effect data in snapshots (not Reader config)
    comp =
      ConversationComp.run()
      |> State.with_handler(initial_state, tag: ConversationComp)
      |> EffectLogger.with_logging(state_keys: [State.state_key(ConversationComp)])
      |> Reader.with_handler(conversation_config, tag: ConversationComp)
      |> LlmCall.with_handler(llm_handler(config))
      |> Yield.with_handler()
      |> Throw.with_handler()

    # Run until first yield (should be :await_user_input)
    case Comp.run(comp) do
      {%Suspend{value: :await_user_input, resume: resume}, env} ->
        log = EffectLogger.get_log(env)
        {:ok, %__MODULE__{resume_fn: resume, config: config, log: log}}

      {%Suspend{value: other}, _env} ->
        {:error, {:unexpected_yield, other}}

      {%Comp.Throw{error: error}, _env} ->
        {:error, error}

      {value, _env} ->
        {:error, {:unexpected_completion, value}}
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
  def send_message(%__MODULE__{resume_fn: resume} = runner, message) do
    # Resume with user message, catching any exceptions
    try do
      {result, env} = resume.(message)
      log = EffectLogger.get_log(env)
      process_yields(result, %{runner | log: log})
    rescue
      e ->
        {:error, {:exception, Exception.message(e)}, runner}
    catch
      kind, reason ->
        {:error, {kind, reason}, runner}
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
  defp process_yields(%Suspend{value: yield_value, resume: resume}, runner) do
    case yield_value do
      :await_user_input ->
        # Shouldn't happen immediately after sending a message
        # but handle it gracefully by returning an empty response
        {:ok, %{text: "", tool_executions: []}, %{runner | resume_fn: resume}}

      %{type: :execute_tools, tool_uses: tool_requests} ->
        # Execute tools and continue
        results = execute_tools(tool_requests, runner.config.tenant_id)
        {next_result, env} = resume.(results)
        log = EffectLogger.get_log(env)
        process_yields(next_result, %{runner | log: log})

      %{type: :response, text: text, tool_executions: tool_executions} ->
        # Got a response - resume to get back to await_user_input, then return
        {next_result, env} = resume.(:ok)
        log = EffectLogger.get_log(env)
        finalize_response(next_result, %{runner | log: log}, text, tool_executions)

      %{type: :error, reason: reason} ->
        # Error occurred - resume to continue, then return error
        {next_result, env} = resume.(:ok)
        log = EffectLogger.get_log(env)
        finalize_error(next_result, %{runner | log: log}, reason)
    end
  end

  defp process_yields(%Comp.Throw{error: error}, runner) do
    {:error, error, runner}
  end

  defp process_yields(_value, runner) do
    # Computation completed (shouldn't happen for conversation loop)
    {:error, :conversation_ended, runner}
  end

  # After response yield, ensure we're back at await_user_input
  defp finalize_response(
         %Suspend{value: :await_user_input, resume: resume},
         runner,
         text,
         tool_executions
       ) do
    response = %{text: text, tool_executions: tool_executions}
    {:ok, response, %{runner | resume_fn: resume}}
  end

  defp finalize_response(%Suspend{value: other, resume: _resume}, runner, text, tool_executions) do
    # Unexpected yield after response - still return what we have
    response = %{text: text, tool_executions: tool_executions}
    {:error, {:unexpected_yield_after_response, other, response}, runner}
  end

  defp finalize_response(other, runner, _text, _tool_executions) do
    {:error, {:unexpected_result_after_response, other}, runner}
  end

  # After error yield, ensure we're back at await_user_input
  defp finalize_error(%Suspend{value: :await_user_input, resume: resume}, runner, reason) do
    {:error, reason, %{runner | resume_fn: resume}}
  end

  defp finalize_error(_other, runner, reason) do
    {:error, reason, runner}
  end

  # Execute tool requests through the domain stack
  defp execute_tools(tool_requests, tenant_id) do
    Enum.map(tool_requests, &execute_single_tool(&1, tenant_id))
  end

  defp execute_single_tool(%{name: name, input: input}, tenant_id) do
    case Tools.find_module(name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      module ->
        try do
          operation = module.from_json(input)
          Run.execute(operation, tenant_id: tenant_id)
        rescue
          e -> {:error, Exception.message(e)}
        end
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
