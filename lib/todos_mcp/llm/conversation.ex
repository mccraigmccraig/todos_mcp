defmodule TodosMcp.Llm.Conversation do
  @moduledoc """
  Manages LLM chat state and the tool execution loop.

  Holds message history, sends messages to the LLM API, executes tool calls
  via `Run.execute/1`, and returns results to the LLM until it produces a
  final response.

  ## Example

      alias TodosMcp.Llm.Conversation

      # Start a new conversation
      conv = Conversation.new(api_key: "sk-...")

      # Send a message and get the response (may involve multiple tool calls)
      {:ok, conv, response} = Conversation.send_message(conv, "Create a todo for buying milk")

      # The response contains the final text reply
      response.text
      #=> "I've created a todo item for 'buying milk' with medium priority."

      # Tool executions are recorded
      response.tool_executions
      #=> [%{tool: "create_todo", input: %{...}, result: {:ok, %Todo{}}}]
  """

  alias TodosMcp.Llm.Claude
  alias TodosMcp.Mcp.Tools
  alias TodosMcp.Run

  @default_system_prompt """
  You are a helpful assistant that manages a todo list application.
  You have access to tools for creating, updating, listing, and managing todos.
  Use these tools to help the user manage their tasks.
  Be concise in your responses.
  When you perform an action, briefly confirm what you did.
  """

  @max_tool_iterations 10

  defstruct [
    :api_key,
    :system_prompt,
    :model,
    messages: [],
    tools: []
  ]

  @type t :: %__MODULE__{
          api_key: String.t(),
          system_prompt: String.t(),
          model: String.t() | nil,
          messages: [map()],
          tools: [map()]
        }

  @type response :: %{
          text: String.t(),
          tool_executions: [tool_execution()]
        }

  @type tool_execution :: %{
          tool: String.t(),
          input: map(),
          result: {:ok, term()} | {:error, term()}
        }

  @doc """
  Create a new conversation.

  ## Options

  - `:api_key` - Required. Anthropic API key.
  - `:system_prompt` - Custom system prompt (has a sensible default).
  - `:model` - Claude model to use.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    system_prompt = Keyword.get(opts, :system_prompt, @default_system_prompt)
    model = Keyword.get(opts, :model)

    # Convert MCP tools to Claude format once
    tools = Tools.all() |> Claude.convert_tools()

    %__MODULE__{
      api_key: api_key,
      system_prompt: system_prompt,
      model: model,
      messages: [],
      tools: tools
    }
  end

  @doc """
  Send a user message and get the final response.

  This function handles the full tool execution loop:
  1. Sends the message to Claude
  2. If Claude requests tool execution, executes the tools
  3. Sends tool results back to Claude
  4. Repeats until Claude produces a final text response

  Returns `{:ok, updated_conversation, response}` or `{:error, reason}`.
  """
  @spec send_message(t(), String.t()) :: {:ok, t(), response()} | {:error, term()}
  def send_message(%__MODULE__{} = conv, user_message) do
    # Add user message to history
    user_msg = %{role: "user", content: user_message}
    messages = conv.messages ++ [user_msg]

    # Run the conversation loop
    case conversation_loop(conv, messages, [], 0) do
      {:ok, final_messages, tool_executions, final_response} ->
        updated_conv = %{conv | messages: final_messages}

        response = %{
          text: Claude.extract_text(final_response),
          tool_executions: tool_executions
        }

        {:ok, updated_conv, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clear the conversation history while keeping the configuration.
  """
  @spec clear_history(t()) :: t()
  def clear_history(%__MODULE__{} = conv) do
    %{conv | messages: []}
  end

  @doc """
  Get the current message count.
  """
  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{messages: messages}) do
    length(messages)
  end

  # Private functions

  defp conversation_loop(_conv, _messages, _tool_executions, iteration)
       when iteration >= @max_tool_iterations do
    {:error, :max_iterations_exceeded}
  end

  defp conversation_loop(conv, messages, tool_executions, iteration) do
    # Build API options
    opts =
      [
        api_key: conv.api_key,
        tools: conv.tools,
        system: conv.system_prompt
      ]
      |> maybe_add_model(conv.model)

    # Send to Claude
    case Claude.send_messages(messages, opts) do
      {:ok, response} ->
        # Add assistant response to history
        assistant_msg = Claude.assistant_message(response)
        messages = messages ++ [assistant_msg]

        if Claude.needs_tool_execution?(response) do
          # Execute tools and continue
          {tool_results_msg, new_executions} = execute_tools(response)
          messages = messages ++ [tool_results_msg]
          tool_executions = tool_executions ++ new_executions

          conversation_loop(conv, messages, tool_executions, iteration + 1)
        else
          # Final response
          {:ok, messages, tool_executions, response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tools(response) do
    tool_uses = Claude.extract_tool_uses(response)

    # Execute each tool and collect results
    {results, executions} =
      tool_uses
      |> Enum.map(&execute_single_tool/1)
      |> Enum.unzip()

    # Build the tool results message (can contain multiple results)
    tool_results_msg = %{
      role: "user",
      content: results
    }

    {tool_results_msg, executions}
  end

  defp execute_single_tool(tool_use) do
    # Handle both string and atom keys from Claude response
    tool_name = tool_use["name"] || tool_use[:name]
    tool_id = tool_use["id"] || tool_use[:id]
    input = tool_use["input"] || tool_use[:input] || %{}

    result = execute_tool(tool_name, input)

    # Build result content block
    result_block = %{
      type: "tool_result",
      tool_use_id: tool_id,
      content: format_result(result)
    }

    execution = %{
      tool: tool_name,
      input: input,
      result: result
    }

    {result_block, execution}
  end

  defp execute_tool(tool_name, input) do
    case Tools.find_module(tool_name) do
      nil ->
        {:error, "Unknown tool: #{tool_name}"}

      module ->
        try do
          # Convert input to struct and execute
          operation = module.from_json(input)
          Run.execute(operation)
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  defp format_result({:ok, value}) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_result({:error, reason}) do
    "Error: #{inspect(reason)}"
  end

  defp maybe_add_model(opts, nil), do: opts
  defp maybe_add_model(opts, model), do: Keyword.put(opts, :model, model)
end
