defmodule TodosMcp.Todos.Queries do
  @moduledoc """
  Query structs for reading todos.

  All queries are serializable and have documentation for MCP tool generation.
  """

  defmodule ListTodos do
    @moduledoc "List todos with optional filtering and sorting"
    @derive Jason.Encoder
    defstruct filter: :all, sort_by: :inserted_at, sort_order: :desc

    @type t :: %__MODULE__{
            filter: :all | :active | :completed,
            sort_by: :inserted_at | :title | :priority | :due_date,
            sort_order: :asc | :desc
          }

    def from_json(map) when is_map(map) do
      %__MODULE__{
        filter: map |> Map.get("filter", "all") |> to_atom(),
        sort_by: map |> Map.get("sort_by", "inserted_at") |> to_atom(),
        sort_order: map |> Map.get("sort_order", "desc") |> to_atom()
      }
    end

    defp to_atom(str) when is_binary(str), do: String.to_existing_atom(str)
    defp to_atom(atom) when is_atom(atom), do: atom
  end

  defmodule GetTodo do
    @moduledoc "Get a single todo by ID"
    @derive Jason.Encoder
    defstruct [:id]

    @type t :: %__MODULE__{id: String.t()}

    def from_json(map) when is_map(map) do
      %__MODULE__{id: Map.fetch!(map, "id")}
    end
  end

  defmodule SearchTodos do
    @moduledoc "Search todos by title and description"
    @derive Jason.Encoder
    defstruct [:query, limit: 20]

    @type t :: %__MODULE__{
            query: String.t(),
            limit: integer()
          }

    def from_json(map) when is_map(map) do
      %__MODULE__{
        query: Map.fetch!(map, "query"),
        limit: Map.get(map, "limit", 20)
      }
    end
  end

  defmodule GetStats do
    @moduledoc "Get todo statistics (total, active, completed counts)"
    @derive Jason.Encoder
    defstruct []

    @type t :: %__MODULE__{}

    def from_json(_map), do: %__MODULE__{}
  end

  @doc "List all query modules for MCP tool registration"
  def all do
    [ListTodos, GetTodo, SearchTodos, GetStats]
  end
end
