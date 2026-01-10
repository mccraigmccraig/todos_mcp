defmodule TodosMcp.Todo do
  @moduledoc """
  The Todo schema representing a todo item.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "todos" do
    field(:title, :string)
    field(:description, :string, default: "")
    field(:completed, :boolean, default: false)
    field(:priority, Ecto.Enum, values: [:low, :medium, :high], default: :medium)
    field(:due_date, :date)
    field(:tags, {:array, :string}, default: [])
    field(:position, :integer)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:title]
  @optional_fields [:description, :completed, :priority, :due_date, :tags, :position]

  @doc false
  def changeset(todo, attrs) do
    todo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:description, max: 4096)
  end
end
