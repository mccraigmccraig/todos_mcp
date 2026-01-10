defmodule TodosMcp.Mcp.ServerTest do
  use ExUnit.Case, async: false

  alias TodosMcp.Mcp.Server

  describe "start_link/1" do
    test "starts the server with process-based I/O" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          input: {:process, test_pid},
          output: {:process, test_pid}
        )

      assert Process.alive?(server)

      # Send EOF to trigger shutdown
      send(server, :eof)

      # Wait for process to terminate
      ref = Process.monitor(server)
      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 1000
    end

    test "can be started with a name" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          input: {:process, test_pid},
          output: {:process, test_pid},
          name: :test_mcp_server
        )

      assert Process.whereis(:test_mcp_server) == server

      Server.stop(:test_mcp_server)
    end
  end

  describe "message handling" do
    test "processes JSON-RPC line and sends response" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          input: {:process, test_pid},
          output: {:process, test_pid}
        )

      # Send a ping request
      request =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}})

      send(server, {:line, request})

      # Should receive output
      assert_receive {:output, response}, 1000

      parsed = Jason.decode!(response)
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 1
      assert parsed["result"] == %{}

      Server.stop(server)
    end

    test "handles tools/list request" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          input: {:process, test_pid},
          output: {:process, test_pid}
        )

      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        })

      send(server, {:line, request})

      assert_receive {:output, response}, 1000

      parsed = Jason.decode!(response)
      assert is_list(parsed["result"]["tools"])
      assert length(parsed["result"]["tools"]) == 10

      Server.stop(server)
    end

    test "handles invalid JSON" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          input: {:process, test_pid},
          output: {:process, test_pid}
        )

      send(server, {:line, "not valid json"})

      assert_receive {:output, response}, 1000

      parsed = Jason.decode!(response)
      assert parsed["error"]["code"] == -32700

      Server.stop(server)
    end
  end

  describe "shutdown" do
    test "stops gracefully on explicit stop" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          input: {:process, test_pid},
          output: {:process, test_pid}
        )

      ref = Process.monitor(server)

      Server.stop(server)

      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 1000
    end
  end
end
