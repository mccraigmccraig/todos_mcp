defmodule TodosMcp.Mcp.Tools do
  @moduledoc """
  Generate MCP tool definitions from Command and Query structs.

  MCP tools follow the Model Context Protocol specification:
  - `name`: snake_case identifier for the tool
  - `description`: human-readable description (from @moduledoc)
  - `inputSchema`: JSON Schema for tool arguments

  ## Example

      iex> TodosMcp.Mcp.Tools.all()
      [
        %{
          name: "create_todo",
          description: "Create a new todo item",
          inputSchema: %{
            type: "object",
            properties: %{
              title: %{type: "string"},
              description: %{type: "string"},
              ...
            },
            required: ["title"]
          }
        },
        ...
      ]
  """

  alias TodosMcp.{Commands, Queries}

  @doc """
  Returns all available MCP tools (commands + queries).
  """
  def all do
    command_tools() ++ query_tools()
  end

  @doc """
  Returns MCP tool definitions for all commands.
  """
  def command_tools do
    Commands.all() |> Enum.map(&to_tool/1)
  end

  @doc """
  Returns MCP tool definitions for all queries.
  """
  def query_tools do
    Queries.all() |> Enum.map(&to_tool/1)
  end

  @doc """
  Convert a Command or Query module to an MCP tool definition.
  """
  def to_tool(module) do
    %{
      name: tool_name(module),
      description: tool_description(module),
      inputSchema: input_schema(module)
    }
  end

  @doc """
  Find a tool module by name.
  """
  def find_module(name) when is_binary(name) do
    all_modules()
    |> Enum.find(fn mod -> tool_name(mod) == name end)
  end

  @doc """
  List all command and query modules.
  """
  def all_modules do
    Commands.all() ++ Queries.all()
  end

  # Generate tool name from module (e.g., TodosMcp.Commands.CreateTodo -> "create_todo")
  defp tool_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  # Extract description from module's @moduledoc
  defp tool_description(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} -> doc
      {:docs_v1, _, _, _, doc, _, _} when is_binary(doc) -> doc
      _ -> "No description available"
    end
  end

  # Generate JSON Schema for the module's struct
  defp input_schema(module) do
    struct_info = struct_fields(module)
    defaults = struct_defaults(module)

    properties =
      struct_info
      |> Enum.reject(fn {k, _} -> k == :__struct__ end)
      |> Enum.map(fn {field, _type} ->
        {field, field_schema(module, field)}
      end)
      |> Map.new()

    required =
      struct_info
      |> Enum.reject(fn {k, _} -> k == :__struct__ end)
      |> Enum.filter(fn {field, _} ->
        # Required if no default value (default is nil and field doesn't allow nil)
        Map.get(defaults, field) == nil && is_required_field?(module, field)
      end)
      |> Enum.map(fn {field, _} -> Atom.to_string(field) end)

    schema = %{
      type: "object",
      properties: properties
    }

    if required == [] do
      schema
    else
      Map.put(schema, :required, required)
    end
  end

  # Get struct field names and their types from @type t
  defp struct_fields(module) do
    # Fallback: get fields from struct definition
    module.__struct__()
    |> Map.from_struct()
    |> Enum.map(fn {k, _v} -> {k, :any} end)
  end

  # Get default values from struct
  defp struct_defaults(module) do
    module.__struct__()
    |> Map.from_struct()
  end

  # Check if a field is required based on module-specific rules
  defp is_required_field?(module, field) do
    required_fields = required_fields_for(module)
    field in required_fields
  end

  # Define required fields for each operation type
  # These are fields that MUST be provided (not optional)
  defp required_fields_for(module) do
    module_name = module |> Module.split() |> List.last()

    case module_name do
      "CreateTodo" -> [:title]
      "UpdateTodo" -> [:id]
      "ToggleTodo" -> [:id]
      "DeleteTodo" -> [:id]
      "GetTodo" -> [:id]
      "SearchTodos" -> [:query]
      # These have no required fields
      "CompleteAll" -> []
      "ClearCompleted" -> []
      "ListTodos" -> []
      "GetStats" -> []
      _ -> []
    end
  end

  # Generate JSON Schema for a specific field
  defp field_schema(module, field) do
    # Use field name heuristics for schema type
    case field do
      :id ->
        %{type: "string", description: "Todo ID (UUID)"}

      :title ->
        %{type: "string", description: "Todo title"}

      :description ->
        %{type: "string", description: "Todo description"}

      :query ->
        %{type: "string", description: "Search query string"}

      :priority ->
        priority_schema()

      :due_date ->
        %{type: "string", format: "date", description: "Due date (ISO 8601)"}

      :tags ->
        %{type: "array", items: %{type: "string"}, description: "List of tags"}

      :completed ->
        %{type: "boolean", description: "Whether todo is completed"}

      :filter ->
        filter_schema()

      :sort_by ->
        sort_by_schema()

      :sort_order ->
        sort_order_schema()

      :limit ->
        %{
          type: "integer",
          description: "Maximum number of results",
          default: default_for(module, field)
        }

      _ ->
        %{type: "string"}
    end
  end

  defp default_for(module, field) do
    module.__struct__()
    |> Map.get(field)
  end

  defp priority_schema do
    %{
      type: "string",
      enum: ["low", "medium", "high"],
      description: "Priority level",
      default: "medium"
    }
  end

  defp filter_schema do
    %{
      type: "string",
      enum: ["all", "active", "completed"],
      description: "Filter todos by status",
      default: "all"
    }
  end

  defp sort_by_schema do
    %{
      type: "string",
      enum: ["inserted_at", "title", "priority", "due_date"],
      description: "Field to sort by",
      default: "inserted_at"
    }
  end

  defp sort_order_schema do
    %{
      type: "string",
      enum: ["asc", "desc"],
      description: "Sort order",
      default: "desc"
    }
  end
end
