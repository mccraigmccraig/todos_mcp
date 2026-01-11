defmodule TodosMcp.Llm.Groq do
  @moduledoc """
  HTTP client for the Groq API (OpenAI-compatible).

  Groq provides fast inference for open-source models with a generous free tier.
  The API is OpenAI-compatible, using the chat completions endpoint with
  function calling support.

  ## Example

      alias TodosMcp.Llm.Groq

      tools = Groq.convert_tools(mcp_tools)

      case Groq.send_messages(messages, tools: tools, api_key: key) do
        {:ok, response} ->
          if Groq.needs_tool_execution?(response) do
            # Handle tool calls
          else
            Groq.extract_text(response)
          end
        {:error, reason} -> # API error
      end
  """

  @api_url "https://api.groq.com/openai/v1/chat/completions"
  @default_model "llama-3.3-70b-versatile"

  @type message :: %{role: String.t(), content: String.t() | nil, tool_calls: list() | nil}

  @type tool_call :: %{
          id: String.t(),
          type: String.t(),
          function: %{name: String.t(), arguments: String.t()}
        }

  @type response :: %{
          choices: [choice()],
          usage: %{prompt_tokens: integer(), completion_tokens: integer()} | nil,
          raw: map()
        }

  @type choice :: %{
          message: message(),
          finish_reason: String.t() | nil
        }

  @doc """
  Send messages to Groq and receive a response.

  ## Options

  - `:api_key` - Required. Groq API key.
  - `:tools` - List of tool definitions (use `convert_tools/1` to convert from MCP format).
  - `:system` - System message (will be prepended to messages).
  - `:model` - Model to use (default: #{@default_model}).

  ## Returns

  - `{:ok, response}` - Successful response.
  - `{:error, reason}` - API error or network failure.
  """
  @spec send_messages([map()], keyword()) :: {:ok, response()} | {:error, term()}
  def send_messages(messages, opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    tools = Keyword.get(opts, :tools, [])
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model, @default_model)

    # Convert messages to OpenAI format and prepend system message
    openai_messages =
      messages
      |> convert_messages()
      |> maybe_prepend_system(system)

    body =
      %{model: model, messages: openai_messages}
      |> maybe_add_tools(tools)

    case do_request(api_key, body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        error_msg = get_in(body, ["error", "message"]) || inspect(body)
        {:error, {:api_error, status, error_msg}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Convert MCP/Claude tool definitions to OpenAI function format.

  OpenAI/Groq uses `parameters` in JSON Schema format within a `function` wrapper.
  """
  @spec convert_tools([map()]) :: [map()]
  def convert_tools(mcp_tools) do
    Enum.map(mcp_tools, fn tool ->
      # Handle both MCP format (inputSchema) and Claude format (input_schema)
      schema =
        tool[:input_schema] || tool[:inputSchema] ||
          tool["input_schema"] || tool["inputSchema"] ||
          %{type: "object", properties: %{}}

      %{
        type: "function",
        function: %{
          name: tool[:name] || tool["name"],
          description: tool[:description] || tool["description"],
          parameters: normalize_schema(schema)
        }
      }
    end)
  end

  @doc """
  Extract text content from a response.
  """
  @spec extract_text(response()) :: String.t()
  def extract_text(response) do
    response.choices
    |> List.first(%{})
    |> get_in([:message, :content])
    |> Kernel.||("")
  end

  @doc """
  Extract tool calls from a response.
  """
  @spec extract_tool_calls(response()) :: [tool_call()]
  def extract_tool_calls(response) do
    response.choices
    |> List.first(%{})
    |> get_in([:message, :tool_calls])
    |> List.wrap()
    |> Enum.filter(&(&1 != nil))
  end

  @doc """
  Check if response requires tool execution.
  """
  @spec needs_tool_execution?(response()) :: boolean()
  def needs_tool_execution?(response) do
    extract_tool_calls(response) != []
  end

  @doc """
  Build the assistant message from a response (for conversation history).
  """
  @spec assistant_message(response()) :: map()
  def assistant_message(response) do
    response.choices
    |> List.first(%{})
    |> Map.get(:message, %{role: "assistant", content: ""})
  end

  @doc """
  Build tool result messages for sending results back.
  """
  @spec tool_result_messages([{String.t(), term()}]) :: [map()]
  def tool_result_messages(results) do
    Enum.map(results, fn {tool_call_id, result} ->
      %{
        role: "tool",
        tool_call_id: tool_call_id,
        content: format_tool_result(result)
      }
    end)
  end

  # Private functions

  defp do_request(api_key, body) do
    Req.post(@api_url,
      json: body,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ],
      receive_timeout: 120_000
    )
  end

  defp convert_messages(messages) do
    Enum.flat_map(messages, &convert_message/1)
  end

  defp convert_message(%{role: "user", content: content}) when is_binary(content) do
    [%{role: "user", content: content}]
  end

  defp convert_message(%{role: "user", content: content}) when is_list(content) do
    # Handle Claude-style content blocks (tool results)
    # Check if this is a tool results message
    if Enum.all?(content, &is_tool_result?/1) do
      # Convert tool results to OpenAI format
      Enum.map(content, fn block ->
        %{
          role: "tool",
          tool_call_id: block[:tool_use_id] || block["tool_use_id"],
          content: block[:content] || block["content"] || ""
        }
      end)
    else
      # Regular content blocks - extract text
      text =
        content
        |> Enum.filter(&((&1[:type] || &1["type"]) == "text"))
        |> Enum.map(&(&1[:text] || &1["text"]))
        |> Enum.join("\n")

      [%{role: "user", content: text}]
    end
  end

  defp convert_message(%{role: "assistant", content: content}) when is_binary(content) do
    [%{role: "assistant", content: content}]
  end

  defp convert_message(%{role: "assistant", content: content}) when is_list(content) do
    # Handle Claude-style assistant messages with tool_use blocks
    text_parts =
      content
      |> Enum.filter(&((&1[:type] || &1["type"]) == "text"))
      |> Enum.map(&(&1[:text] || &1["text"]))
      |> Enum.join("\n")

    tool_calls =
      content
      |> Enum.filter(&((&1[:type] || &1["type"]) == "tool_use"))
      |> Enum.map(fn block ->
        %{
          id: block[:id] || block["id"],
          type: "function",
          function: %{
            name: block[:name] || block["name"],
            arguments: Jason.encode!(block[:input] || block["input"] || %{})
          }
        }
      end)

    msg = %{role: "assistant", content: if(text_parts == "", do: nil, else: text_parts)}
    msg = if tool_calls != [], do: Map.put(msg, :tool_calls, tool_calls), else: msg

    [msg]
  end

  defp convert_message(%{"role" => role, "content" => content}) do
    convert_message(%{role: role, content: content})
  end

  defp convert_message(msg) do
    # Fallback - pass through
    [msg]
  end

  defp is_tool_result?(block) do
    type = block[:type] || block["type"]
    type == "tool_result"
  end

  defp maybe_prepend_system(messages, nil), do: messages

  defp maybe_prepend_system(messages, system) do
    [%{role: "system", content: system} | messages]
  end

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    body
    |> Map.put(:tools, tools)
    |> Map.put(:tool_choice, "auto")
  end

  defp normalize_schema(schema) when is_map(schema) do
    # Ensure proper JSON Schema format
    schema
    |> Map.take([:type, :properties, :required, "type", "properties", "required"])
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      other -> other
    end)
    |> Map.new()
    |> Map.put_new("type", "object")
  end

  defp parse_response(body) do
    choices =
      (body["choices"] || [])
      |> Enum.map(fn c ->
        %{
          message: parse_message(c["message"]),
          finish_reason: c["finish_reason"]
        }
      end)

    usage =
      case body["usage"] do
        nil ->
          nil

        u ->
          %{
            prompt_tokens: u["prompt_tokens"] || 0,
            completion_tokens: u["completion_tokens"] || 0
          }
      end

    %{
      choices: choices,
      usage: usage,
      raw: body
    }
  end

  defp parse_message(nil), do: %{role: "assistant", content: ""}

  defp parse_message(msg) do
    base = %{
      role: msg["role"] || "assistant",
      content: msg["content"]
    }

    case msg["tool_calls"] do
      nil ->
        base

      tool_calls ->
        Map.put(base, :tool_calls, Enum.map(tool_calls, &parse_tool_call/1))
    end
  end

  defp parse_tool_call(tc) do
    %{
      id: tc["id"],
      type: tc["type"] || "function",
      function: %{
        name: get_in(tc, ["function", "name"]),
        arguments: get_in(tc, ["function", "arguments"]) || "{}"
      }
    }
  end

  defp format_tool_result({:ok, value}) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"
  defp format_tool_result(value) when is_binary(value), do: value

  defp format_tool_result(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
