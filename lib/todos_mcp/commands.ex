defmodule TodosMcp.Commands do
  @moduledoc """
  Command structs for todo mutations.

  All commands are serializable and have documentation for MCP tool generation.
  """

  defmodule CreateTodo do
    @moduledoc "Create a new todo item"
    @derive Jason.Encoder
    defstruct [:title, description: "", priority: :medium, due_date: nil, tags: []]

    @type t :: %__MODULE__{
            title: String.t(),
            description: String.t(),
            priority: :low | :medium | :high,
            due_date: Date.t() | nil,
            tags: [String.t()]
          }

    def from_json(map) when is_map(map) do
      %__MODULE__{
        title: Map.fetch!(map, "title"),
        description: Map.get(map, "description", ""),
        priority: map |> Map.get("priority", "medium") |> to_priority(),
        due_date: map |> Map.get("due_date") |> parse_date(),
        tags: Map.get(map, "tags", [])
      }
    end

    defp to_priority("low"), do: :low
    defp to_priority("medium"), do: :medium
    defp to_priority("high"), do: :high
    defp to_priority(atom) when is_atom(atom), do: atom

    defp parse_date(nil), do: nil
    defp parse_date(""), do: nil
    defp parse_date(%Date{} = d), do: d
    defp parse_date(str) when is_binary(str), do: Date.from_iso8601!(str)
  end

  defmodule UpdateTodo do
    @moduledoc "Update an existing todo item (nil fields are not changed)"
    @derive Jason.Encoder
    defstruct [:id, :title, :description, :priority, :due_date, :tags]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t() | nil,
            description: String.t() | nil,
            priority: :low | :medium | :high | nil,
            due_date: Date.t() | nil,
            tags: [String.t()] | nil
          }

    def from_json(map) when is_map(map) do
      %__MODULE__{
        id: Map.fetch!(map, "id"),
        title: Map.get(map, "title"),
        description: Map.get(map, "description"),
        priority: map |> Map.get("priority") |> to_priority(),
        due_date: map |> Map.get("due_date") |> parse_date(),
        tags: Map.get(map, "tags")
      }
    end

    defp to_priority(nil), do: nil
    defp to_priority("low"), do: :low
    defp to_priority("medium"), do: :medium
    defp to_priority("high"), do: :high
    defp to_priority(atom) when is_atom(atom), do: atom

    defp parse_date(nil), do: nil
    defp parse_date(""), do: nil
    defp parse_date(%Date{} = d), do: d
    defp parse_date(str) when is_binary(str), do: Date.from_iso8601!(str)
  end

  defmodule ToggleTodo do
    @moduledoc "Toggle the completed status of a todo"
    @derive Jason.Encoder
    defstruct [:id]

    @type t :: %__MODULE__{id: String.t()}

    def from_json(map) when is_map(map) do
      %__MODULE__{id: Map.fetch!(map, "id")}
    end
  end

  defmodule DeleteTodo do
    @moduledoc "Delete a todo item"
    @derive Jason.Encoder
    defstruct [:id]

    @type t :: %__MODULE__{id: String.t()}

    def from_json(map) when is_map(map) do
      %__MODULE__{id: Map.fetch!(map, "id")}
    end
  end

  defmodule CompleteAll do
    @moduledoc "Mark all todos as completed"
    @derive Jason.Encoder
    defstruct []

    @type t :: %__MODULE__{}

    def from_json(_map), do: %__MODULE__{}
  end

  defmodule ClearCompleted do
    @moduledoc "Delete all completed todos"
    @derive Jason.Encoder
    defstruct []

    @type t :: %__MODULE__{}

    def from_json(_map), do: %__MODULE__{}
  end

  @doc "List all command modules for MCP tool registration"
  def all do
    [CreateTodo, UpdateTodo, ToggleTodo, DeleteTodo, CompleteAll, ClearCompleted]
  end
end
