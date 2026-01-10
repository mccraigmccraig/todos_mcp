defmodule TodosMcp.DataAccess do
  @moduledoc """
  Data access layer for todos.

  Public functions return `Skuld.Effects.Query.request/3` computations,
  keeping the Query effect abstraction while providing a clean API.

  Use `!` variants when you expect the record to exist - they will
  raise via the Throw effect if not found. Plain variants return nil.

  ## Example

      comp do
        todo <- DataAccess.get_todo!(id)
        # ... work with todo
      end
  """

  alias Skuld.Effects.Query

  # Get a single todo by ID (returns nil if not found)
  def get_todo(id), do: Query.request(__MODULE__.Impl, :get_todo, %{id: id})

  # Get a single todo by ID (throws if not found)
  def get_todo!(id), do: Query.request(__MODULE__.Impl, :get_todo!, %{id: id})

  # List todos with optional filtering and sorting
  def list_todos(opts \\ %{})

  def list_todos(opts) when is_list(opts), do: list_todos(Map.new(opts))

  def list_todos(opts) when is_map(opts) do
    Query.request(__MODULE__.Impl, :list_todos, opts)
  end

  # List only incomplete todos
  def list_incomplete, do: Query.request(__MODULE__.Impl, :list_incomplete, %{})

  # List only completed todos
  def list_completed, do: Query.request(__MODULE__.Impl, :list_completed, %{})

  # Search todos by title/description
  def search_todos(query, limit \\ 20) do
    Query.request(__MODULE__.Impl, :search_todos, %{query: query, limit: limit})
  end

  # Get statistics (total, active, completed counts)
  def get_stats, do: Query.request(__MODULE__.Impl, :get_stats, %{})

  # Implementation module with actual Ecto queries
  defmodule Impl do
    @moduledoc false

    import Ecto.Query
    alias TodosMcp.{Repo, Todo}
    alias Skuld.Effects.Throw

    def get_todo(%{id: id}) do
      Repo.get(Todo, id)
    end

    def get_todo!(%{id: id}) do
      case Repo.get(Todo, id) do
        nil -> Throw.throw({:not_found, Todo, id})
        todo -> todo
      end
    end

    def list_todos(opts) do
      filter = Map.get(opts, :filter, :all)
      sort_by = Map.get(opts, :sort_by, :inserted_at)
      sort_order = Map.get(opts, :sort_order, :desc)

      Todo
      |> apply_filter(filter)
      |> apply_sort(sort_by, sort_order)
      |> Repo.all()
    end

    def list_incomplete(%{}) do
      from(t in Todo, where: t.completed == false)
      |> Repo.all()
    end

    def list_completed(%{}) do
      from(t in Todo, where: t.completed == true)
      |> Repo.all()
    end

    def search_todos(%{query: search_query, limit: limit}) do
      search_pattern = "%#{search_query}%"

      from(t in Todo,
        where: ilike(t.title, ^search_pattern) or ilike(t.description, ^search_pattern),
        limit: ^limit,
        order_by: [desc: t.inserted_at]
      )
      |> Repo.all()
    end

    def get_stats(%{}) do
      total = Repo.aggregate(Todo, :count)
      completed = Repo.aggregate(from(t in Todo, where: t.completed == true), :count)
      active = total - completed

      %{total: total, active: active, completed: completed}
    end

    # Private helpers

    defp apply_filter(query, :all), do: query
    defp apply_filter(query, :active), do: where(query, [t], t.completed == false)
    defp apply_filter(query, :completed), do: where(query, [t], t.completed == true)

    defp apply_sort(query, field, :asc), do: order_by(query, [t], asc: ^field)
    defp apply_sort(query, field, :desc), do: order_by(query, [t], desc: ^field)
  end
end
