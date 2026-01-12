defmodule TodosMcp.Mcp.ProtocolTest do
  # async: false because in-memory mode uses shared state
  use TodosMcp.DataCase, async: false

  alias TodosMcp.Mcp.Protocol
  alias TodosMcp.{InMemoryStore, Run}
  alias TodosMcp.Todos.Commands.{CreateTodo, ToggleTodo}
  alias TodosMcp.Todos.Queries.{GetTodo, ListTodos}

  setup do
    # Clear in-memory store before each test (when in in_memory mode)
    if Application.get_env(:todos_mcp, :storage_mode, :in_memory) == :in_memory do
      InMemoryStore.clear()
    end

    :ok
  end

  # Helper to create a todo via Run.execute (works in both database and in_memory modes)
  defp create_todo!(attrs) do
    {:ok, todo} =
      Run.execute(%CreateTodo{
        title: attrs[:title] || attrs["title"],
        description: attrs[:description] || attrs["description"],
        priority: attrs[:priority] || attrs["priority"] || :medium
      })

    # If completed is requested, toggle it
    if attrs[:completed] || attrs["completed"] do
      {:ok, todo} = Run.execute(%ToggleTodo{id: todo.id})
      todo
    else
      todo
    end
  end

  # Helper to make JSON-RPC request and parse response
  defp call(method, params \\ %{}, id \\ 1) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    Protocol.handle(request)
  end

  describe "initialize" do
    test "returns server info and capabilities" do
      response = call("initialize", %{"clientInfo" => %{"name" => "test"}})

      assert response.jsonrpc == "2.0"
      assert response.id == 1
      assert response.result.protocolVersion == "2024-11-05"
      assert response.result.serverInfo.name == "todos_mcp"
      assert response.result.capabilities.tools == %{}
    end
  end

  describe "tools/list" do
    test "returns all available tools" do
      response = call("tools/list")

      assert response.jsonrpc == "2.0"
      assert response.id == 1
      assert is_list(response.result.tools)
      assert length(response.result.tools) == 10

      names = Enum.map(response.result.tools, & &1.name)
      assert "create_todo" in names
      assert "list_todos" in names
    end
  end

  describe "tools/call" do
    test "executes get_stats tool" do
      create_todo!(%{title: "Test 1", completed: false})
      create_todo!(%{title: "Test 2", completed: true})

      response = call("tools/call", %{"name" => "get_stats"})

      assert response.jsonrpc == "2.0"
      assert [content] = response.result.content
      assert content.type == "text"

      result = Jason.decode!(content.text)
      assert result["total"] == 2
      assert result["active"] == 1
      assert result["completed"] == 1
    end

    test "executes list_todos tool" do
      todo1 = create_todo!(%{title: "First"})
      todo2 = create_todo!(%{title: "Second"})

      response = call("tools/call", %{"name" => "list_todos"})

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert length(result) == 2
      ids = Enum.map(result, & &1["id"])
      assert todo1.id in ids
      assert todo2.id in ids
    end

    test "executes list_todos with filter" do
      _active = create_todo!(%{title: "Active", completed: false})
      completed = create_todo!(%{title: "Done", completed: true})

      response =
        call("tools/call", %{
          "name" => "list_todos",
          "arguments" => %{"filter" => "completed"}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert length(result) == 1
      assert hd(result)["id"] == completed.id
    end

    test "executes create_todo tool" do
      response =
        call("tools/call", %{
          "name" => "create_todo",
          "arguments" => %{"title" => "New Todo", "priority" => "high"}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert result["title"] == "New Todo"
      assert result["priority"] == "high"
      assert is_binary(result["id"])

      # Verify persisted
      assert {:ok, _} = Run.execute(%GetTodo{id: result["id"]})
    end

    test "executes get_todo tool" do
      todo = create_todo!(%{title: "Find Me"})

      response =
        call("tools/call", %{
          "name" => "get_todo",
          "arguments" => %{"id" => todo.id}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert result["id"] == todo.id
      assert result["title"] == "Find Me"
    end

    test "returns error for get_todo with invalid id" do
      response =
        call("tools/call", %{
          "name" => "get_todo",
          "arguments" => %{"id" => Uniq.UUID.uuid7()}
        })

      assert response.result.isError == true
      assert [content] = response.result.content
      result = Jason.decode!(content.text)
      assert result["error"] =~ "not_found" or result["error"] =~ "Not found"
    end

    test "executes toggle_todo tool" do
      todo = create_todo!(%{title: "Toggle Me", completed: false})

      response =
        call("tools/call", %{
          "name" => "toggle_todo",
          "arguments" => %{"id" => todo.id}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert result["completed"] == true

      # Toggle back
      response2 =
        call("tools/call", %{
          "name" => "toggle_todo",
          "arguments" => %{"id" => todo.id}
        })

      result2 = response2.result.content |> hd() |> Map.get(:text) |> Jason.decode!()
      assert result2["completed"] == false
    end

    test "executes update_todo tool" do
      todo = create_todo!(%{title: "Old Title", priority: :low})

      response =
        call("tools/call", %{
          "name" => "update_todo",
          "arguments" => %{"id" => todo.id, "title" => "New Title", "priority" => "high"}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert result["title"] == "New Title"
      assert result["priority"] == "high"
    end

    test "executes delete_todo tool" do
      todo = create_todo!(%{title: "Delete Me"})

      response =
        call("tools/call", %{
          "name" => "delete_todo",
          "arguments" => %{"id" => todo.id}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)
      assert result["id"] == todo.id

      # Verify deleted
      assert {:error, :not_found} = Run.execute(%GetTodo{id: todo.id})
    end

    test "executes search_todos tool" do
      create_todo!(%{title: "Buy milk"})
      create_todo!(%{title: "Buy eggs"})
      create_todo!(%{title: "Walk dog"})

      response =
        call("tools/call", %{
          "name" => "search_todos",
          "arguments" => %{"query" => "Buy"}
        })

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert length(result) == 2
      assert Enum.all?(result, fn t -> String.contains?(t["title"], "Buy") end)
    end

    test "executes complete_all tool" do
      create_todo!(%{title: "Task 1", completed: false})
      create_todo!(%{title: "Task 2", completed: false})
      create_todo!(%{title: "Task 3", completed: true})

      response = call("tools/call", %{"name" => "complete_all"})

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert result["updated"] == 2
    end

    test "executes clear_completed tool" do
      create_todo!(%{title: "Active", completed: false})
      create_todo!(%{title: "Done 1", completed: true})
      create_todo!(%{title: "Done 2", completed: true})

      response = call("tools/call", %{"name" => "clear_completed"})

      assert [content] = response.result.content
      result = Jason.decode!(content.text)

      assert result["deleted"] == 2

      # Verify only active remains
      {:ok, remaining} = Run.execute(%ListTodos{})
      assert length(remaining) == 1
    end

    test "returns error for unknown tool" do
      response = call("tools/call", %{"name" => "unknown_tool"})

      assert response.error.code == -32602
      assert response.error.message =~ "Unknown tool"
    end

    test "returns error for missing required argument" do
      response =
        call("tools/call", %{
          "name" => "create_todo",
          "arguments" => %{}
        })

      assert response.error.code == -32602
      assert response.error.message =~ "title"
    end
  end

  describe "error handling" do
    test "returns parse error for invalid JSON" do
      response = Protocol.handle_request("not valid json")

      assert response =~ "Parse error"
      parsed = Jason.decode!(response)
      assert parsed["error"]["code"] == -32700
    end

    test "returns method not found for unknown method" do
      response = call("unknown/method")

      assert response.error.code == -32601
      assert response.error.message =~ "Method not found"
    end

    test "returns invalid request for missing jsonrpc version" do
      request = %{"id" => 1, "method" => "tools/list"}
      response = Protocol.handle(request)

      assert response.error.code == -32600
    end
  end

  describe "ping" do
    test "responds to ping" do
      response = call("ping")

      assert response.jsonrpc == "2.0"
      assert response.result == %{}
    end
  end
end
