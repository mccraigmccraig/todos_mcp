defmodule TodosMcp.Mcp.Server do
  @moduledoc """
  MCP Server using stdio transport.

  Reads JSON-RPC messages from stdin (one per line), processes them through
  the Protocol module, and writes responses to stdout.

  ## Usage

  Start the server:

      TodosMcp.Mcp.Server.start_link([])

  Or use the mix task:

      mix todos_mcp.mcp

  The server will read from stdin and write to stdout, making it compatible
  with MCP clients like Claude Desktop.
  """

  use GenServer
  require Logger

  alias TodosMcp.Mcp.Protocol

  @doc """
  Starts the MCP server.

  Options:
    - `:input` - input device (default: :stdio)
    - `:output` - output device (default: :stdio)
    - `:name` - GenServer name (optional)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Stops the MCP server.
  """
  def stop(server \\ __MODULE__) do
    GenServer.stop(server)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)

    # Start reading from input in a separate process (unless using process-based I/O for testing)
    reader_pid =
      case input do
        {:process, _} ->
          # For testing - messages sent directly to server, no read loop needed
          nil

        _ ->
          spawn_link(fn -> read_loop(self(), input) end)
      end

    state = %{
      input: input,
      output: output,
      reader_pid: reader_pid
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:line, line}, state) do
    # Process the incoming JSON-RPC message
    response = Protocol.handle_request(line)

    # Send response if not nil (notifications don't get responses)
    if response do
      write_response(state.output, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:error, reason}, state) do
    Logger.error("MCP Server input error: #{inspect(reason)}")
    {:stop, {:error, reason}, state}
  end

  @impl true
  def handle_info(:eof, state) do
    Logger.info("MCP Server received EOF, shutting down")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up reader process
    if state.reader_pid && Process.alive?(state.reader_pid) do
      Process.exit(state.reader_pid, :shutdown)
    end

    :ok
  end

  # Private functions

  # Read loop - runs in a separate process
  defp read_loop(server, input) do
    case read_line(input) do
      {:ok, line} ->
        send(server, {:line, line})
        read_loop(server, input)

      {:error, reason} ->
        send(server, {:error, reason})

      :eof ->
        send(server, :eof)
    end
  end

  # Read a line from input
  defp read_line(:stdio) do
    case IO.gets("") do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      line when is_binary(line) -> {:ok, String.trim_trailing(line, "\n")}
    end
  end

  defp read_line({:io_device, device}) do
    case IO.gets(device, "") do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      line when is_binary(line) -> {:ok, String.trim_trailing(line, "\n")}
    end
  end

  # For testing with process-based input
  # The ref should be a pid that will send {:input, line} or :eof messages
  defp read_line({:process, _source_pid}) do
    receive do
      {:input, line} -> {:ok, line}
      :eof -> :eof
    after
      60_000 -> {:error, :timeout}
    end
  end

  # Write response to output
  defp write_response(:stdio, response) do
    IO.puts(response)
  end

  defp write_response({:io_device, device}, response) do
    IO.puts(device, response)
  end

  defp write_response({:process, pid}, response) do
    send(pid, {:output, response})
  end
end
