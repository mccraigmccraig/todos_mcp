defmodule TodosMcp.Mcp.Protocol do
  @moduledoc """
  MCP (Model Context Protocol) JSON-RPC handler.

  Implements the MCP protocol for tool discovery and execution:
  - `initialize` - server capabilities and info
  - `tools/list` - returns available tools
  - `tools/call` - executes a tool and returns result

  ## JSON-RPC Format

  Request:
      {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}

  Response:
      {"jsonrpc": "2.0", "id": 1, "result": {...}}

  Error:
      {"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message": "..."}}
  """

  alias TodosMcp.Mcp.Tools
  alias TodosMcp.Run

  @server_name "todos_mcp"
  @server_version "0.1.0"
  @protocol_version "2024-11-05"

  # JSON-RPC error codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  @doc """
  Handle a JSON-RPC request string.

  Returns a JSON response string.
  """
  @spec handle_request(String.t()) :: String.t()
  def handle_request(json) do
    json
    |> parse_request()
    |> dispatch()
    |> encode_response()
  end

  @doc """
  Handle a parsed JSON-RPC request map.

  Returns a response map.
  """
  @spec handle(map()) :: map()
  def handle(request) do
    request
    |> dispatch()
  end

  # Parse JSON request
  defp parse_request(json) do
    case Jason.decode(json) do
      {:ok, request} -> request
      {:error, _} -> %{"error" => :parse_error}
    end
  end

  # Encode response to JSON
  defp encode_response(response) do
    Jason.encode!(response)
  end

  # Dispatch to appropriate handler
  defp dispatch(%{"error" => :parse_error}) do
    error_response(nil, @parse_error, "Parse error")
  end

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = request) do
    params = Map.get(request, "params", %{})

    case handle_method(method, params) do
      {:ok, result} -> success_response(id, result)
      {:error, {code, message}} -> error_response(id, code, message)
      {:error, message} -> error_response(id, @internal_error, format_error_message(message))
    end
  end

  # Notifications (no id) - MCP uses these for some messages
  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = request) do
    params = Map.get(request, "params", %{})
    # Handle notification, don't send response
    handle_notification(method, params)
    nil
  end

  defp dispatch(_invalid) do
    error_response(nil, @invalid_request, "Invalid request")
  end

  # Method handlers

  defp handle_method("initialize", params) do
    # Client info is in params, we respond with server capabilities
    _client_info = Map.get(params, "clientInfo", %{})

    {:ok,
     %{
       protocolVersion: @protocol_version,
       serverInfo: %{
         name: @server_name,
         version: @server_version
       },
       capabilities: %{
         tools: %{}
       }
     }}
  end

  defp handle_method("tools/list", _params) do
    tools = Tools.all()
    {:ok, %{tools: tools}}
  end

  defp handle_method("tools/call", %{"name" => name, "arguments" => arguments}) do
    call_tool(name, arguments)
  end

  defp handle_method("tools/call", %{"name" => name}) do
    # Arguments are optional for tools with no required params
    call_tool(name, %{})
  end

  defp handle_method("tools/call", _params) do
    {:error, {@invalid_params, "Missing required parameter: name"}}
  end

  defp handle_method("ping", _params) do
    {:ok, %{}}
  end

  defp handle_method(method, _params) do
    {:error, {@method_not_found, "Method not found: #{method}"}}
  end

  # Notification handlers (no response expected)

  defp handle_notification("notifications/initialized", _params) do
    # Client has finished initialization
    :ok
  end

  defp handle_notification("notifications/cancelled", _params) do
    # Request was cancelled
    :ok
  end

  defp handle_notification(_method, _params) do
    # Unknown notification, ignore
    :ok
  end

  # Tool execution

  defp call_tool(name, arguments) do
    case Tools.find_module(name) do
      nil ->
        {:error, {@invalid_params, "Unknown tool: #{name}"}}

      module ->
        execute_tool(module, arguments)
    end
  end

  defp execute_tool(module, arguments) do
    try do
      # Convert JSON arguments to operation struct
      operation = module.from_json(arguments)

      # Execute through the domain layer
      case Run.execute(operation) do
        {:ok, result} ->
          {:ok, format_tool_result(result)}

        {:error, reason} ->
          {:ok, format_tool_error(reason)}
      end
    rescue
      e in KeyError ->
        {:error, {@invalid_params, "Missing required argument: #{e.key}"}}

      e ->
        {:error, {@internal_error, Exception.message(e)}}
    end
  end

  # Format successful tool result for MCP
  defp format_tool_result(result) do
    %{
      content: [
        %{
          type: "text",
          text: Jason.encode!(result)
        }
      ]
    }
  end

  # Format tool error for MCP (still a "success" in JSON-RPC terms, but indicates tool failure)
  defp format_tool_error(reason) do
    %{
      content: [
        %{
          type: "text",
          text: Jason.encode!(%{error: format_error_reason(reason)})
        }
      ],
      isError: true
    }
  end

  defp format_error_reason({:not_found, _schema, id}), do: "Not found: #{id}"
  defp format_error_reason(:not_found), do: "Not found"
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error_reason(reason), do: inspect(reason)

  defp format_error_message(message) when is_binary(message), do: message
  defp format_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp format_error_message(message), do: inspect(message)

  # Response builders

  defp success_response(id, result) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: result
    }
  end

  defp error_response(id, code, message) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{
        code: code,
        message: message
      }
    }
  end
end
