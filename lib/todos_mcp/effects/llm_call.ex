defmodule TodosMcp.Effects.LlmCall do
  @moduledoc """
  LlmCall effect - LLM API communication within conversation computations.

  This effect handles sending messages to an LLM and receiving responses.
  It's designed to be internal to conversation computations - multiple LLM
  calls can happen without crossing a Yield boundary.

  ## Response Format

  Handlers should return a normalized response map:

      %{
        text: String.t(),           # Extracted text content
        tool_uses: [tool_use()],    # Tool use requests (if any)
        needs_tools: boolean(),     # Whether tool execution is needed
        raw: term()                 # Original provider response
      }

  ## Usage

      use Skuld.Syntax
      alias TodosMcp.Effects.LlmCall

      defcomp my_conversation(messages) do
        response <- LlmCall.send_messages(messages, tools: my_tools)

        if response.needs_tools do
          # Handle tool execution...
        else
          response.text
        end
      end
      |> LlmCall.with_handler(ClaudeHandler.handler(api_key: key))
      |> Comp.run()

  ## Handlers

  - `ClaudeHandler` - Anthropic Claude API
  - `TestHandler` - Stubbed responses for testing
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Type Definitions
  #############################################################################

  @type message :: %{role: String.t(), content: String.t() | list()}

  @type tool_use :: %{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @type response :: %{
          text: String.t(),
          tool_uses: [tool_use()],
          needs_tools: boolean(),
          provider: atom(),
          raw: term()
        }

  @type handler_fn :: (op :: term() -> response() | {:error, term()})

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(SendMessages, [:messages, :opts])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Send messages to the LLM and receive a response.

  ## Arguments

  - `messages` - List of message maps with `:role` and `:content` keys
  - `opts` - Keyword options passed to the handler:
    - `:tools` - List of tool definitions
    - `:system` - System prompt
    - Other handler-specific options

  ## Returns

  A computation that, when run with a handler, returns a response map.

  ## Example

      defcomp chat_turn(messages, tools) do
        response <- LlmCall.send_messages(messages, tools: tools)
        response.text
      end
  """
  @spec send_messages(list(message()), keyword()) :: Types.computation()
  def send_messages(messages, opts \\ []) do
    Comp.effect(@sig, %SendMessages{messages: messages, opts: opts})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install an LlmCall handler for a computation.

  The handler function receives the operation struct and should return
  a response map or `{:error, reason}`.

  ## Example

      my_computation
      |> LlmCall.with_handler(fn %SendMessages{messages: msgs, opts: opts} ->
        # Call LLM API and return normalized response
        %{text: "Hello!", tool_uses: [], needs_tools: false, raw: %{}}
      end)
      |> Comp.run()
  """
  @spec with_handler(Types.computation(), handler_fn()) :: Types.computation()
  def with_handler(comp, handler_fn) do
    Comp.with_handler(comp, @sig, fn op, env, k ->
      case handler_fn.(op) do
        {:error, _} = error ->
          k.(error, env)

        response ->
          k.(response, env)
      end
    end)
  end

  #############################################################################
  ## Signature Access (for testing/introspection)
  #############################################################################

  @doc false
  def signature, do: @sig
end
