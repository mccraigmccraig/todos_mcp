defmodule TodosMcp.Mcp.ToolsTest do
  use ExUnit.Case, async: true

  alias TodosMcp.Mcp.Tools

  alias TodosMcp.Commands.{
    CreateTodo,
    UpdateTodo,
    ToggleTodo,
    DeleteTodo,
    CompleteAll,
    ClearCompleted
  }

  alias TodosMcp.Queries.{ListTodos, GetTodo, SearchTodos, GetStats}

  describe "all/0" do
    test "returns all command and query tools" do
      tools = Tools.all()

      assert length(tools) == 10
      names = Enum.map(tools, & &1.name)

      # Commands
      assert "create_todo" in names
      assert "update_todo" in names
      assert "toggle_todo" in names
      assert "delete_todo" in names
      assert "complete_all" in names
      assert "clear_completed" in names

      # Queries
      assert "list_todos" in names
      assert "get_todo" in names
      assert "search_todos" in names
      assert "get_stats" in names
    end
  end

  describe "to_tool/1" do
    test "generates correct tool definition for CreateTodo" do
      tool = Tools.to_tool(CreateTodo)

      assert tool.name == "create_todo"
      assert tool.description == "Create a new todo item"
      assert tool.inputSchema.type == "object"
      assert tool.inputSchema.required == ["title"]
      assert Map.has_key?(tool.inputSchema.properties, :title)
      assert Map.has_key?(tool.inputSchema.properties, :description)
      assert Map.has_key?(tool.inputSchema.properties, :priority)
    end

    test "generates correct tool definition for UpdateTodo" do
      tool = Tools.to_tool(UpdateTodo)

      assert tool.name == "update_todo"
      assert tool.inputSchema.required == ["id"]
      # title should NOT be required for updates
      refute "title" in tool.inputSchema.required
    end

    test "generates correct tool definition for ToggleTodo" do
      tool = Tools.to_tool(ToggleTodo)

      assert tool.name == "toggle_todo"
      assert tool.inputSchema.required == ["id"]
      assert map_size(tool.inputSchema.properties) == 1
    end

    test "generates correct tool definition for DeleteTodo" do
      tool = Tools.to_tool(DeleteTodo)

      assert tool.name == "delete_todo"
      assert tool.inputSchema.required == ["id"]
    end

    test "generates correct tool definition for CompleteAll" do
      tool = Tools.to_tool(CompleteAll)

      assert tool.name == "complete_all"
      refute Map.has_key?(tool.inputSchema, :required)
      assert tool.inputSchema.properties == %{}
    end

    test "generates correct tool definition for ClearCompleted" do
      tool = Tools.to_tool(ClearCompleted)

      assert tool.name == "clear_completed"
      refute Map.has_key?(tool.inputSchema, :required)
    end

    test "generates correct tool definition for ListTodos" do
      tool = Tools.to_tool(ListTodos)

      assert tool.name == "list_todos"
      refute Map.has_key?(tool.inputSchema, :required)
      assert Map.has_key?(tool.inputSchema.properties, :filter)
      assert Map.has_key?(tool.inputSchema.properties, :sort_by)
      assert Map.has_key?(tool.inputSchema.properties, :sort_order)
    end

    test "generates correct tool definition for GetTodo" do
      tool = Tools.to_tool(GetTodo)

      assert tool.name == "get_todo"
      assert tool.inputSchema.required == ["id"]
    end

    test "generates correct tool definition for SearchTodos" do
      tool = Tools.to_tool(SearchTodos)

      assert tool.name == "search_todos"
      assert tool.inputSchema.required == ["query"]
      assert Map.has_key?(tool.inputSchema.properties, :query)
      assert Map.has_key?(tool.inputSchema.properties, :limit)
    end

    test "generates correct tool definition for GetStats" do
      tool = Tools.to_tool(GetStats)

      assert tool.name == "get_stats"
      refute Map.has_key?(tool.inputSchema, :required)
      assert tool.inputSchema.properties == %{}
    end
  end

  describe "find_module/1" do
    test "finds command modules by name" do
      assert Tools.find_module("create_todo") == CreateTodo
      assert Tools.find_module("update_todo") == UpdateTodo
      assert Tools.find_module("toggle_todo") == ToggleTodo
      assert Tools.find_module("delete_todo") == DeleteTodo
      assert Tools.find_module("complete_all") == CompleteAll
      assert Tools.find_module("clear_completed") == ClearCompleted
    end

    test "finds query modules by name" do
      assert Tools.find_module("list_todos") == ListTodos
      assert Tools.find_module("get_todo") == GetTodo
      assert Tools.find_module("search_todos") == SearchTodos
      assert Tools.find_module("get_stats") == GetStats
    end

    test "returns nil for unknown tool" do
      assert Tools.find_module("unknown_tool") == nil
    end
  end

  describe "input schema properties" do
    test "priority field has enum values" do
      tool = Tools.to_tool(CreateTodo)
      priority = tool.inputSchema.properties.priority

      assert priority.type == "string"
      assert priority.enum == ["low", "medium", "high"]
      assert priority.default == "medium"
    end

    test "filter field has enum values" do
      tool = Tools.to_tool(ListTodos)
      filter = tool.inputSchema.properties.filter

      assert filter.type == "string"
      assert filter.enum == ["all", "active", "completed"]
      assert filter.default == "all"
    end

    test "limit field has integer type with default" do
      tool = Tools.to_tool(SearchTodos)
      limit = tool.inputSchema.properties.limit

      assert limit.type == "integer"
      assert limit.default == 20
    end

    test "tags field is array of strings" do
      tool = Tools.to_tool(CreateTodo)
      tags = tool.inputSchema.properties.tags

      assert tags.type == "array"
      assert tags.items == %{type: "string"}
    end

    test "due_date field has date format" do
      tool = Tools.to_tool(CreateTodo)
      due_date = tool.inputSchema.properties.due_date

      assert due_date.type == "string"
      assert due_date.format == "date"
    end
  end
end
