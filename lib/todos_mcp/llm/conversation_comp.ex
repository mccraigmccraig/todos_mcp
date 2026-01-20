defmodule TodosMcp.Llm.ConversationComp do
  @moduledoc """
  Long-lived conversation computation using Skuld effects.

  This module provides a conversation loop as a Skuld computation that:
  - Yields `:await_user_input` to wait for user messages
  - Uses `LlmCall` effect for LLM communication (internal, doesn't yield)
  - Yields `{:execute_tools, tool_uses}` when tools need execution
  - Yields `{:response, text, tool_executions}` to notify of assistant responses
  - Loops indefinitely, maintaining conversation state

  ## Architecture

  The computation uses two types of effects:
  - **LlmCall** - Internal effect for LLM API calls, handled within the computation
  - **Yield** - Boundary effect for communication with the environment

  This separation means multiple LLM calls can happen (e.g., after tool execution)
  without crossing the Yield boundary.

  ## Yield Protocol

  | Yield Value                     | Direction | Purpose                                |
  |---------------------------------|-----------|----------------------------------------|
  | `:await_user_input`             | out → in  | Wait for user message (returns String) |
  | `{:execute_tools, [tool_use]}`  | out → in  | Execute tools (returns [result])       |
  | `{:response, text, tool_execs}` | out       | Notify UI of response                  |

  ## Usage

  Use `build/1` to create a computation with all handlers installed,
  then run it with `AsyncRunner`:

      alias Skuld.AsyncRunner
      alias TodosMcp.Llm.ConversationComp

      # Build computation with all handlers
      comp = ConversationComp.build(api_key: "sk-...", provider: :claude)

      # Start with AsyncRunner
      {:ok, runner, {:yield, :await_user_input, _data}} =
        AsyncRunner.start_sync(comp, tag: :llm, link: false)

      # Send user message (async)
      AsyncRunner.resume(runner, "Hello!")

      # Handle yields in process mailbox
      receive do
        {:llm, :yield, %{type: :response, text: text}, _data} ->
          IO.puts("Assistant: \#{text}")
          AsyncRunner.resume(runner, :ok)  # Resume to get back to await_user_input

        {:llm, :yield, %{type: :execute_tools, tool_uses: tools}, _data} ->
          results = execute_tools(tools)
          AsyncRunner.resume(runner, results)  # Resume with tool results
      end
  """

  use Skuld.Syntax

  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State, as: StateEffect
  alias Skuld.Effects.Yield
  alias TodosMcp.Effects.LlmCall
  alias TodosMcp.Effects.LlmCall.ClaudeHandler
  alias TodosMcp.Effects.LlmCall.GeminiHandler
  alias TodosMcp.Effects.LlmCall.GroqHandler
  alias TodosMcp.Llm.Claude
  alias TodosMcp.Mcp.Tools

  # Loop markers for EffectLogger pruning
  defmodule ConversationLoop do
    @moduledoc false
  end

  defmodule ToolIterationLoop do
    @moduledoc false
  end

  @default_system_prompt """
  You are a helpful assistant that manages a todo list application.
  You have access to tools for creating, updating, listing, and managing todos.
  Use these tools to help the user manage their tasks.
  Be concise in your responses.
  When you perform an action, briefly confirm what you did.
  """

  @max_tool_iterations 10

  @doc "Get the default system prompt"
  @spec default_system_prompt() :: String.t()
  def default_system_prompt, do: @default_system_prompt

  #############################################################################
  ## Config (constant, via Reader - not logged)
  #############################################################################

  defmodule Config do
    @moduledoc "Constant conversation configuration (tools, system prompt)"
    @derive Jason.Encoder
    defstruct tools: [],
              system: nil
  end

  @type config :: %Config{
          tools: [map()],
          system: String.t() | nil
        }

  @doc """
  Create conversation config.

  ## Options

  - `:tools` - Tool definitions in Claude format (default: [])
  - `:system` - System prompt (default: built-in todo assistant prompt)
  """
  @spec initial_config(keyword()) :: config()
  def initial_config(opts \\ []) do
    %Config{
      tools: Keyword.get(opts, :tools, []),
      system: Keyword.get(opts, :system, @default_system_prompt)
    }
  end

  #############################################################################
  ## State (mutable, via State effect - logged)
  #############################################################################

  defmodule State do
    @moduledoc "Mutable conversation state (message history, errors)"
    @derive Jason.Encoder
    defstruct messages: [],
              last_error: nil,
              error_count: 0
  end

  @type state :: %State{
          messages: [map()],
          last_error: term(),
          error_count: non_neg_integer()
        }

  @doc """
  Create initial conversation state.

  ## Options

  - `:messages` - Initial messages (default: [])
  """
  @spec initial_state(keyword()) :: state()
  def initial_state(opts \\ []) do
    %State{
      messages: Keyword.get(opts, :messages, []),
      last_error: nil,
      error_count: 0
    }
  end

  #############################################################################
  ## Build Computation with Handlers
  #############################################################################

  @doc """
  Build a conversation computation with all handlers installed.

  Returns a computation ready to be started with `AsyncRunner.start/2` or
  `AsyncRunner.start_sync/2`.

  ## Options

  - `:api_key` - Required. API key for the selected provider.
  - `:provider` - LLM provider (`:claude`, `:gemini`, or `:groq`). Default: `:claude`.
  - `:system` - System prompt (optional, has sensible default).
  - `:model` - Model to use (optional, provider-specific default).
  - `:tools` - Tool definitions (optional, defaults to all MCP tools in Claude format).

  ## Example

      comp = ConversationComp.build(api_key: "sk-...", provider: :claude)
      {:ok, runner, {:yield, :await_user_input, _}} = AsyncRunner.start_sync(comp, tag: :llm)
  """
  @spec build(keyword()) :: Skuld.Comp.Types.computation()
  def build(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    provider = Keyword.get(opts, :provider, :claude)
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model)

    # Get tools in Claude format (GeminiHandler will convert as needed)
    tools =
      Keyword.get_lazy(opts, :tools, fn ->
        Tools.all() |> Claude.convert_tools()
      end)

    # Build config (constant - via Reader, not logged)
    conversation_config =
      initial_config(
        tools: tools,
        system: system || @default_system_prompt
      )

    # Build initial state (mutable - via State, logged)
    initial_state = initial_state()

    # Build LLM handler based on provider
    llm_handler = build_llm_handler(api_key, provider, system, model, tools)

    # Build the computation with handlers
    # Reader is outside EffectLogger (config lookups not logged)
    # State is inside EffectLogger (state changes are logged for cold resume)
    # EffectLogger decorates suspends with the log via suspend.data
    run()
    |> StateEffect.with_handler(initial_state, tag: __MODULE__)
    |> EffectLogger.with_logging(state_keys: [StateEffect.state_key(__MODULE__)])
    |> Reader.with_handler(conversation_config, tag: __MODULE__)
    |> LlmCall.with_handler(llm_handler)
  end

  defp build_llm_handler(api_key, provider, system, model, tools) do
    base_opts =
      [api_key: api_key]
      |> maybe_add(:system, system)
      |> maybe_add(:model, model)
      |> maybe_add(:tools, tools)

    case provider do
      :gemini -> GeminiHandler.handler(base_opts)
      :groq -> GroqHandler.handler(base_opts)
      _claude -> ClaudeHandler.handler(base_opts)
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  #############################################################################
  ## Main Conversation Loop
  #############################################################################

  @doc """
  Run the conversation loop.

  This is a long-lived computation that:
  1. Yields `:await_user_input` and waits for a user message
  2. Sends the message to the LLM via LlmCall effect
  3. If tools are needed, yields `{:execute_tools, ...}` and continues with results
  4. Yields `{:response, text, tool_executions}` with the final response
  5. Loops back to step 1

  The computation never terminates normally - it loops forever.
  Use the Yield handler to control when to stop.

  Config (tools, system) is via Reader effect - constant, not logged.
  State (messages) is via State effect - mutable, logged for cold resume.
  """
  defcomp run() do
    # Mark loop iteration for EffectLogger pruning
    _ <- EffectLogger.mark_loop(ConversationLoop)

    # Get config (constant) via Reader effect - not logged
    config <- Reader.ask(__MODULE__)

    # Get current state (mutable) via State effect - logged
    state <- StateEffect.get(__MODULE__)

    # Wait for user input
    user_message <- Yield.yield(:await_user_input)

    # Add user message to history
    user_msg = %{role: "user", content: user_message}
    messages = state.messages ++ [user_msg]

    # Get LLM response (may involve tool execution loop)
    result <- conversation_turn(messages, config.tools, [], 0)

    case result do
      {:ok, final_text, final_messages, tool_executions} ->
        comp do
          # Yield the response to the UI (use map for JSON serialization)
          _yielded <-
            Yield.yield(%{type: :response, text: final_text, tool_executions: tool_executions})

          # Update state with new messages
          _ <- StateEffect.put(__MODULE__, %{state | messages: final_messages})

          # Loop
          run()
        end

      {:error, reason} ->
        comp do
          # Record error in state for debugging
          _ <-
            StateEffect.put(__MODULE__, %{
              state
              | last_error: format_error_for_state(reason),
                error_count: state.error_count + 1
            })

          # Yield error and continue (use map for JSON serialization)
          _yielded <- Yield.yield(%{type: :error, reason: reason})

          run()
        end
    end
  end

  #############################################################################
  ## Conversation Turn (may involve multiple LLM calls)
  #############################################################################

  defcompp conversation_turn(messages, tools, tool_executions, iteration) do
    if iteration >= @max_tool_iterations do
      {:error, :max_tool_iterations}
    else
      comp do
        # Mark tool iteration loop for EffectLogger pruning
        _ <- EffectLogger.mark_loop(ToolIterationLoop)

        response <- LlmCall.send_messages(messages, tools: tools)

        case response do
          {:error, reason} ->
            {:error, reason}

          _ ->
            updated_messages = messages ++ [assistant_message(response)]
            handle_response(response, updated_messages, tools, tool_executions, iteration)
        end
      end
    end
  end

  defcompp handle_response(response, messages, tools, tool_executions, iteration) do
    if response.needs_tools do
      comp do
        # Use map for JSON serialization
        tool_results <- Yield.yield(%{type: :execute_tools, tool_uses: response.tool_uses})

        result_msg = tool_results_message(response.tool_uses, tool_results)
        updated_messages = messages ++ [result_msg]

        new_executions = build_tool_executions(response.tool_uses, tool_results)
        all_executions = tool_executions ++ new_executions

        conversation_turn(updated_messages, tools, all_executions, iteration + 1)
      end
    else
      {:ok, response.text, messages, tool_executions}
    end
  end

  #############################################################################
  ## Message Building Helpers
  #############################################################################

  @doc false
  def assistant_message(response) do
    # Build assistant message from response content
    # The raw response has the original content blocks
    # Handle both atom and string keys (from JSON parsing)
    content = response.raw[:content] || response.raw["content"]
    provider = response[:provider] || response["provider"]

    %{role: "assistant", content: content}
    |> maybe_add_provider(provider)
  end

  defp maybe_add_provider(msg, nil), do: msg
  defp maybe_add_provider(msg, provider), do: Map.put(msg, :provider, provider)

  @doc false
  def tool_results_message(tool_uses, results) do
    # Build a message containing all tool results
    content =
      tool_uses
      |> Enum.zip(results)
      |> Enum.map(fn {tool_use, result} ->
        %{
          type: "tool_result",
          tool_use_id: tool_use.id,
          content: format_tool_result(result)
        }
      end)

    %{role: "user", content: content}
  end

  defp format_tool_result({:ok, value}) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_tool_result({:error, reason}) do
    "Error: #{inspect(reason)}"
  end

  defp format_tool_result(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp build_tool_executions(tool_uses, results) do
    tool_uses
    |> Enum.zip(results)
    |> Enum.map(fn {tool_use, result} ->
      %{
        tool: tool_use.name,
        id: tool_use.id,
        input: tool_use.input,
        result: result
      }
    end)
  end

  # Format errors for state storage (must be JSON-serializable)
  defp format_error_for_state({:api_error, status, body}) do
    %{type: "api_error", status: status, body: safe_inspect(body)}
  end

  defp format_error_for_state({:request_failed, reason}) do
    %{type: "request_failed", reason: safe_inspect(reason)}
  end

  defp format_error_for_state(:max_tool_iterations) do
    %{type: "max_tool_iterations"}
  end

  defp format_error_for_state(reason) do
    %{type: "unknown", reason: safe_inspect(reason)}
  end

  defp safe_inspect(term) do
    try do
      case Jason.encode(term) do
        {:ok, _} -> term
        {:error, _} -> inspect(term)
      end
    rescue
      _ -> inspect(term)
    end
  end
end
