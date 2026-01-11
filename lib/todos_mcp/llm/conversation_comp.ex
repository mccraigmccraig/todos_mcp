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

  | Yield Value | Direction | Purpose |
  |-------------|-----------|---------|
  | `:await_user_input` | out → in | Wait for user message (returns String) |
  | `{:execute_tools, [tool_use]}` | out → in | Execute tools (returns [result]) |
  | `{:response, text, tool_execs}` | out | Notify UI of response |

  ## Usage

  The computation should be run with a ConversationRunner that handles
  the Yield effects and composes the LlmCall handler.

  ## Example

      alias TodosMcp.Llm.ConversationComp
      alias TodosMcp.Effects.LlmCall

      # Create initial state
      state = ConversationComp.initial_state(
        tools: my_tools,
        system: "You are helpful"
      )

      # Build computation with handlers
      comp = ConversationComp.run(state)
      |> LlmCall.with_handler(ClaudeHandler.handler(api_key: key))
      |> Yield.with_handler()

      # Run and handle yields (typically done by ConversationRunner)
      case Comp.run(comp) do
        {%Suspend{value: :await_user_input, resume: resume}, _env} ->
          # Provide user input and continue
          resume.("Hello!")
        ...
      end
  """

  use Skuld.Syntax

  alias Skuld.Effects.{EffectLogger, Yield}
  alias Skuld.Effects.State, as: StateEffect
  alias TodosMcp.Effects.LlmCall

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
  ## State
  #############################################################################

  defmodule State do
    @moduledoc "Conversation state"
    defstruct messages: [],
              tools: [],
              system: nil
  end

  @type state :: %State{
          messages: [map()],
          tools: [map()],
          system: String.t() | nil
        }

  @doc """
  Create initial conversation state.

  ## Options

  - `:tools` - Tool definitions in Claude format (default: [])
  - `:system` - System prompt (default: built-in todo assistant prompt)
  - `:messages` - Initial messages (default: [])
  """
  @spec initial_state(keyword()) :: state()
  def initial_state(opts \\ []) do
    %State{
      tools: Keyword.get(opts, :tools, []),
      system: Keyword.get(opts, :system, @default_system_prompt),
      messages: Keyword.get(opts, :messages, [])
    }
  end

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

  State is managed via the State effect with tag `ConversationComp`, which
  ensures it gets captured in the EffectLogger for cold resume.
  """
  defcomp run() do
    # Mark loop iteration for EffectLogger pruning
    _ <- EffectLogger.mark_loop(ConversationLoop)

    # Get current state via State effect
    state <- StateEffect.get(__MODULE__)

    # Wait for user input
    user_message <- Yield.yield(:await_user_input)

    # Add user message to history
    user_msg = %{role: "user", content: user_message}
    messages = state.messages ++ [user_msg]

    # Get LLM response (may involve tool execution loop)
    result <- conversation_turn(messages, state.tools, [], 0)

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
          # Yield error and continue (use map for JSON serialization)
          _yielded <- Yield.yield(%{type: :error, reason: reason})
          # State unchanged on error
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
    %{role: "assistant", content: content}
  end

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
end
