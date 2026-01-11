defmodule TodosMcp.Llm.Claude do
  @moduledoc """
  HTTP client for the Claude Messages API.

  Sends messages with tool definitions and receives responses containing
  text or tool_use blocks. Uses Req for HTTP communication.

  ## Example

      alias TodosMcp.Llm.Claude
      alias TodosMcp.Mcp.Tools

      tools = Tools.all() |> Claude.convert_tools()

      case Claude.chat("Create a todo for buying milk", tools: tools, api_key: key) do
        {:ok, response} ->
          case response.stop_reason do
            "end_turn" -> # Final text response
            "tool_use" -> # Needs tool execution
          end
        {:error, reason} -> # API error
      end
  """

  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096
  @api_version "2023-06-01"

  @type message :: %{role: String.t(), content: String.t() | list()}
  @type tool :: %{name: String.t(), description: String.t(), input_schema: map()}
  @type content_block :: text_block() | tool_use_block()
  @type text_block :: %{type: String.t(), text: String.t()}
  @type tool_use_block :: %{type: String.t(), id: String.t(), name: String.t(), input: map()}

  @type response :: %{
          id: String.t(),
          model: String.t(),
          role: String.t(),
          content: [content_block()],
          stop_reason: String.t() | nil,
          usage: %{input_tokens: integer(), output_tokens: integer()}
        }

  @doc """
  Send a chat message to Claude and receive a response.

  ## Options

  - `:api_key` - Required. Anthropic API key.
  - `:tools` - List of tool definitions (use `convert_tools/1` to convert from MCP format).
  - `:messages` - List of previous messages for multi-turn conversation.
  - `:system` - System prompt.
  - `:model` - Model to use (default: #{@default_model}).
  - `:max_tokens` - Maximum tokens in response (default: #{@default_max_tokens}).

  ## Returns

  - `{:ok, response}` - Successful response with content blocks.
  - `{:error, reason}` - API error or network failure.
  """
  @spec chat(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def chat(user_message, opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    tools = Keyword.get(opts, :tools, [])
    previous_messages = Keyword.get(opts, :messages, [])
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    messages = previous_messages ++ [%{role: "user", content: user_message}]

    send_messages(messages,
      api_key: api_key,
      tools: tools,
      system: system,
      model: model,
      max_tokens: max_tokens
    )
  end

  @doc """
  Send a list of messages to Claude (for continuing conversations).

  Use this when you need to continue a conversation with tool results.

  ## Options

  Same as `chat/2`.
  """
  @spec send_messages([message()], keyword()) :: {:ok, response()} | {:error, term()}
  def send_messages(messages, opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    tools = Keyword.get(opts, :tools, [])
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    # Sanitize messages to only include fields Claude expects
    sanitized_messages = sanitize_messages(messages)

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: sanitized_messages
      }
      |> maybe_add_tools(tools)
      |> maybe_add_system(system)

    case do_request(body, api_key) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Convert MCP tool definitions to Claude tool format.

  MCP tools use `inputSchema`, Claude uses `input_schema`.
  """
  @spec convert_tools([map()]) :: [tool()]
  def convert_tools(mcp_tools) do
    Enum.map(mcp_tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.inputSchema
      }
    end)
  end

  @doc """
  Build a tool result message to send back to Claude.

  After executing a tool, use this to format the result for the next API call.
  """
  @spec tool_result_message(String.t(), term()) :: message()
  def tool_result_message(tool_use_id, result) do
    content =
      case result do
        {:ok, value} -> format_tool_content(value)
        {:error, reason} -> format_error_content(reason)
        value -> format_tool_content(value)
      end

    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: tool_use_id,
          content: content
        }
      ]
    }
  end

  @doc """
  Build an assistant message from a response (for conversation history).
  """
  @spec assistant_message(response()) :: message()
  def assistant_message(response) do
    %{role: "assistant", content: response.content}
  end

  @doc """
  Extract text content from a response.
  """
  @spec extract_text(response()) :: String.t()
  def extract_text(response) do
    response.content
    |> Enum.filter(&(&1["type"] == "text" || &1[:type] == "text"))
    |> Enum.map(&(&1["text"] || &1[:text]))
    |> Enum.join("\n")
  end

  @doc """
  Extract tool use blocks from a response.
  """
  @spec extract_tool_uses(response()) :: [tool_use_block()]
  def extract_tool_uses(response) do
    response.content
    |> Enum.filter(&(&1["type"] == "tool_use" || &1[:type] == "tool_use"))
  end

  @doc """
  Check if response requires tool execution.
  """
  @spec needs_tool_execution?(response()) :: boolean()
  def needs_tool_execution?(response) do
    response.stop_reason == "tool_use"
  end

  # Private functions

  # Sanitize messages to only include fields Claude expects (role, content)
  # This strips any extra metadata like :provider that we add for logging
  defp sanitize_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        role: msg[:role] || msg["role"],
        content: msg[:content] || msg["content"]
      }
    end)
  end

  defp do_request(body, api_key) do
    Req.post(@api_url,
      json: body,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ],
      receive_timeout: 120_000
    )
  end

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system), do: Map.put(body, :system, system)

  defp parse_response(body) do
    %{
      id: body["id"],
      model: body["model"],
      role: body["role"],
      content: body["content"],
      stop_reason: body["stop_reason"],
      usage: %{
        input_tokens: body["usage"]["input_tokens"],
        output_tokens: body["usage"]["output_tokens"]
      }
    }
  end

  defp format_tool_content(value) when is_binary(value), do: value

  defp format_tool_content(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_error_content(reason) do
    "Error: #{inspect(reason)}"
  end
end
