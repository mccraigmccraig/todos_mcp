defmodule TodosMcp.Llm.Gemini do
  @moduledoc """
  HTTP client for the Google Gemini API.

  Sends messages with tool definitions and receives responses containing
  text or function calls. Uses Req for HTTP communication.

  ## Example

      alias TodosMcp.Llm.Gemini

      tools = Gemini.convert_tools(mcp_tools)

      case Gemini.send_messages(messages, tools: tools, api_key: key) do
        {:ok, response} ->
          if Gemini.needs_tool_execution?(response) do
            # Handle function calls
          else
            Gemini.extract_text(response)
          end
        {:error, reason} -> # API error
      end
  """

  @api_base "https://generativelanguage.googleapis.com/v1beta/models"
  @default_model "gemini-2.0-flash"

  @type message :: %{role: String.t(), parts: [map()]}

  @type function_call :: %{
          name: String.t(),
          args: map()
        }

  @type response :: %{
          candidates: [candidate()],
          usage: %{prompt_tokens: integer(), completion_tokens: integer()} | nil,
          raw: map()
        }

  @type candidate :: %{
          content: %{role: String.t(), parts: [map()]},
          finish_reason: String.t() | nil
        }

  @doc """
  Send messages to Gemini and receive a response.

  ## Options

  - `:api_key` - Required. Google AI API key.
  - `:tools` - List of tool definitions (use `convert_tools/1` to convert from MCP format).
  - `:system` - System instruction.
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

    # Convert messages to Gemini format
    contents = convert_messages(messages)

    body =
      %{contents: contents}
      |> maybe_add_tools(tools)
      |> maybe_add_system(system)

    url = "#{@api_base}/#{model}:generateContent?key=#{api_key}"

    case do_request(url, body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Convert MCP tool definitions to Gemini function declarations format.

  MCP tools use `inputSchema`, Gemini uses `parameters` in OpenAPI format.
  """
  @spec convert_tools([map()]) :: [map()]
  def convert_tools(mcp_tools) do
    Enum.map(mcp_tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        parameters: convert_schema(tool.inputSchema || tool[:input_schema])
      }
    end)
  end

  @doc """
  Extract text content from a response.
  """
  @spec extract_text(response()) :: String.t()
  def extract_text(response) do
    response.candidates
    |> List.first(%{})
    |> get_in([:content, :parts])
    |> List.wrap()
    |> Enum.filter(&Map.has_key?(&1, :text))
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
  end

  @doc """
  Extract function calls from a response.
  """
  @spec extract_function_calls(response()) :: [function_call()]
  def extract_function_calls(response) do
    response.candidates
    |> List.first(%{})
    |> get_in([:content, :parts])
    |> List.wrap()
    |> Enum.filter(&Map.has_key?(&1, :functionCall))
    |> Enum.map(fn part ->
      fc = part.functionCall
      %{name: fc.name, args: fc.args || %{}}
    end)
  end

  @doc """
  Check if response requires tool execution.
  """
  @spec needs_tool_execution?(response()) :: boolean()
  def needs_tool_execution?(response) do
    extract_function_calls(response) != []
  end

  @doc """
  Build the assistant message parts from a response (for conversation history).
  """
  @spec assistant_parts(response()) :: [map()]
  def assistant_parts(response) do
    response.candidates
    |> List.first(%{})
    |> get_in([:content, :parts])
    |> List.wrap()
  end

  @doc """
  Build function response parts for sending tool results back.
  """
  @spec function_response_parts([{String.t(), term()}]) :: [map()]
  def function_response_parts(results) do
    Enum.map(results, fn {name, result} ->
      %{
        functionResponse: %{
          name: name,
          response: format_function_result(result)
        }
      }
    end)
  end

  # Private functions

  defp do_request(url, body) do
    Req.post(url,
      json: body,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 120_000
    )
  end

  defp convert_messages(messages) do
    messages
    |> Enum.map(&convert_message/1)
    |> merge_consecutive_roles()
  end

  defp convert_message(%{role: role, content: content} = _msg) when is_binary(content) do
    %{
      role: convert_role(role),
      parts: [%{text: content}]
    }
  end

  defp convert_message(%{role: role, content: content} = _msg) when is_list(content) do
    # Handle Claude-style content blocks
    parts = Enum.flat_map(content, &convert_content_block/1)
    %{role: convert_role(role), parts: parts}
  end

  defp convert_message(%{"role" => role, "content" => content}) do
    convert_message(%{role: role, content: content})
  end

  defp convert_content_block(%{type: "text", text: text}), do: [%{text: text}]
  defp convert_content_block(%{"type" => "text", "text" => text}), do: [%{text: text}]

  defp convert_content_block(%{type: "tool_use", id: _id, name: name, input: input}) do
    [%{functionCall: %{name: name, args: input}}]
  end

  defp convert_content_block(%{
         "type" => "tool_use",
         "id" => _id,
         "name" => name,
         "input" => input
       }) do
    [%{functionCall: %{name: name, args: input}}]
  end

  defp convert_content_block(%{type: "tool_result", tool_use_id: _id, content: content}) do
    # Tool results need to be in a functionResponse - but we need the function name
    # For now, skip these as they should be handled differently
    [%{text: "Tool result: #{content}"}]
  end

  defp convert_content_block(%{
         "type" => "tool_result",
         "tool_use_id" => _id,
         "content" => content
       }) do
    [%{text: "Tool result: #{content}"}]
  end

  defp convert_content_block(other) do
    # Fallback: try to extract text
    text = other[:text] || other["text"] || inspect(other)
    [%{text: text}]
  end

  defp convert_role("assistant"), do: "model"
  defp convert_role("model"), do: "model"
  defp convert_role(_), do: "user"

  # Gemini requires alternating user/model messages, so merge consecutive same-role messages
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(fn chunk ->
      role = List.first(chunk).role
      parts = Enum.flat_map(chunk, & &1.parts)
      %{role: role, parts: parts}
    end)
  end

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    Map.put(body, :tools, [%{functionDeclarations: tools}])
  end

  defp maybe_add_system(body, nil), do: body

  defp maybe_add_system(body, system) do
    Map.put(body, :systemInstruction, %{parts: [%{text: system}]})
  end

  defp convert_schema(nil), do: %{type: "object", properties: %{}}

  defp convert_schema(schema) when is_map(schema) do
    # Gemini uses OpenAPI-style schema, similar to JSON Schema
    # but we need to ensure proper format
    schema
    |> Map.take(["type", "properties", "required", :type, :properties, :required])
    |> Enum.map(fn
      {:type, v} -> {"type", v}
      {"type", v} -> {"type", v}
      {:properties, v} -> {"properties", convert_properties(v)}
      {"properties", v} -> {"properties", convert_properties(v)}
      {:required, v} -> {"required", v}
      {"required", v} -> {"required", v}
      other -> other
    end)
    |> Map.new()
    |> then(fn s ->
      # Ensure type is present
      Map.put_new(s, "type", "object")
    end)
  end

  defp convert_properties(props) when is_map(props) do
    Map.new(props, fn {k, v} ->
      {to_string(k), convert_property(v)}
    end)
  end

  defp convert_property(prop) when is_map(prop) do
    prop
    |> Map.take([
      "type",
      "description",
      "enum",
      "items",
      "default",
      "format",
      :type,
      :description,
      :enum,
      :items,
      :default,
      :format
    ])
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      other -> other
    end)
    |> Map.new()
  end

  defp parse_response(body) do
    candidates =
      (body["candidates"] || [])
      |> Enum.map(fn c ->
        %{
          content: parse_content(c["content"]),
          finish_reason: c["finishReason"]
        }
      end)

    usage =
      case body["usageMetadata"] do
        nil ->
          nil

        meta ->
          %{
            prompt_tokens: meta["promptTokenCount"] || 0,
            completion_tokens: meta["candidatesTokenCount"] || 0
          }
      end

    %{
      candidates: candidates,
      usage: usage,
      raw: body
    }
  end

  defp parse_content(nil), do: %{role: "model", parts: []}

  defp parse_content(content) do
    %{
      role: content["role"] || "model",
      parts: parse_parts(content["parts"] || [])
    }
  end

  defp parse_parts(parts) do
    Enum.map(parts, fn part ->
      cond do
        Map.has_key?(part, "text") ->
          %{text: part["text"]}

        Map.has_key?(part, "functionCall") ->
          fc = part["functionCall"]
          %{functionCall: %{name: fc["name"], args: fc["args"] || %{}}}

        Map.has_key?(part, "functionResponse") ->
          fr = part["functionResponse"]
          %{functionResponse: %{name: fr["name"], response: fr["response"]}}

        true ->
          part
      end
    end)
  end

  defp format_function_result({:ok, value}), do: %{result: value}
  defp format_function_result({:error, reason}), do: %{error: inspect(reason)}
  defp format_function_result(value), do: %{result: value}
end
