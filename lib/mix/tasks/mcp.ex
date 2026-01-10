defmodule Mix.Tasks.TodosMcp.Mcp do
  @moduledoc """
  Starts the TodosMcp MCP server.

  The server reads JSON-RPC messages from stdin and writes responses to stdout,
  making it compatible with MCP clients like Claude Desktop.

  ## Usage

      mix todos_mcp.mcp

  ## Claude Desktop Configuration

  Add to your Claude Desktop config:

      {
        "mcpServers": {
          "todos": {
            "command": "mix",
            "args": ["todos_mcp.mcp"],
            "cwd": "/path/to/todos_mcp"
          }
        }
      }

  Or if using a release:

      {
        "mcpServers": {
          "todos": {
            "command": "/path/to/todos_mcp/bin/todos_mcp",
            "args": ["mcp"]
          }
        }
      }
  """

  use Mix.Task

  @shortdoc "Starts the TodosMcp MCP server"

  @impl Mix.Task
  def run(_args) do
    # Redirect logger to stderr so stdout is reserved for MCP JSON-RPC protocol.
    # We must remove and re-add the handler since `type` can't be changed after start.
    {:ok, handler_config} = :logger.get_handler_config(:default)
    :logger.remove_handler(:default)

    updated_config = put_in(handler_config, [:config, :type], :standard_error)
    :logger.add_handler(:default, handler_config.module, updated_config)

    # Start the application
    {:ok, _} = Application.ensure_all_started(:todos_mcp)

    # Start the MCP server
    {:ok, server} = TodosMcp.Mcp.Server.start_link(name: TodosMcp.Mcp.Server)

    # Log startup (to stderr so it doesn't interfere with MCP protocol on stdout)
    IO.puts(:stderr, "TodosMcp MCP server started. Listening on stdin...")

    # Wait for the server to exit
    ref = Process.monitor(server)

    receive do
      {:DOWN, ^ref, :process, ^server, reason} ->
        IO.puts(:stderr, "MCP server stopped: #{inspect(reason)}")
    end
  end
end
