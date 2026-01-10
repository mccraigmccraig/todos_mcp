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
  alias Skuld.Effects.{Yield, Throw}
  alias TodosMcp.Llm.{ConversationComp, Claude}
  alias TodosMcp.Effects.LlmCall
  alias TodosMcp.Mcp.Tools
  alias TodosMcp.Run

  defstruct [:resume_fn, :config]

  @type t :: %__MODULE__{
          resume_fn: (term() -> {term(), Skuld.Comp.Types.env()}),
          config: map()
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
  Start a new conversation.

  ## Options

  - `:api_key` - Required. Anthropic API key.
  - `:system` - System prompt (optional, has sensible default).
  - `:model` - Claude model to use (optional).
  - `:tools` - Tool definitions (optional, defaults to all MCP tools).

  Returns `{:ok, runner}` when ready for user input.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model)

    # Get tools in Claude format
    tools =
      Keyword.get_lazy(opts, :tools, fn ->
        Tools.all() |> Claude.convert_tools()
      end)

    config = %{
      api_key: api_key,
      system: system,
      model: model,
      tools: tools
    }

    # Build initial state for the conversation computation
    state =
      ConversationComp.initial_state(
        tools: tools,
        system: system || ConversationComp.default_system_prompt()
      )

    # Build the computation with handlers
    comp =
      ConversationComp.run(state)
      |> LlmCall.with_handler(llm_handler(config))
      |> Yield.with_handler()
      |> Throw.with_handler()

    # Run until first yield (should be :await_user_input)
    case Comp.run(comp) do
      {%Suspend{value: :await_user_input, resume: resume}, _env} ->
        {:ok, %__MODULE__{resume_fn: resume, config: config}}

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
    # Resume with user message
    {result, _env} = resume.(message)
    process_yields(result, runner)
  end

  # Process yields until we get a response or await_user_input
  defp process_yields(%Suspend{value: yield_value, resume: resume}, runner) do
    case yield_value do
      :await_user_input ->
        # Shouldn't happen immediately after sending a message
        # but handle it gracefully by returning an empty response
        {:ok, %{text: "", tool_executions: []}, %{runner | resume_fn: resume}}

      {:execute_tools, tool_requests} ->
        # Execute tools and continue
        results = execute_tools(tool_requests)
        {next_result, _env} = resume.(results)
        process_yields(next_result, runner)

      {:response, text, tool_executions} ->
        # Got a response - resume to get back to await_user_input, then return
        {next_result, _env} = resume.(:ok)
        finalize_response(next_result, runner, text, tool_executions)

      {:error, reason} ->
        # Error occurred - resume to continue, then return error
        {next_result, _env} = resume.(:ok)
        finalize_error(next_result, runner, reason)
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
  defp execute_tools(tool_requests) do
    Enum.map(tool_requests, &execute_single_tool/1)
  end

  defp execute_single_tool(%{name: name, input: input}) do
    case Tools.find_module(name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      module ->
        try do
          operation = module.from_json(input)
          Run.execute(operation)
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

    LlmCall.ClaudeHandler.handler(base_opts)
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
