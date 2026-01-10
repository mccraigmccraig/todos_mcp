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
