defmodule TodosMcp.InMemoryPersist do
  @moduledoc """
  In-memory persistence handler compatible with EctoPersist operations.

  Provides an alternative to `EctoPersist.with_handler(Repo)` that stores
  data in `TodosMcp.InMemoryStore` instead of a database.

  ## Usage

      computation
      |> TodosMcp.InMemoryPersist.with_handler()
      |> Comp.run!()

  ## Supported Operations

  - `Insert` - Applies changeset and stores in memory
  - `Update` - Applies changeset and updates in memory
  - `Delete` - Removes from memory
  - `InsertAll`, `UpdateAll`, `DeleteAll` - Bulk operations
  """

  alias Skuld.Comp
  alias Skuld.Comp.Throw, as: ThrowResult
  alias Skuld.Comp.Types
  alias Skuld.Effects.EctoPersist
  alias TodosMcp.InMemoryStore

  @sig EctoPersist

  @doc """
  Install the in-memory persist handler for a computation.

  This replaces `EctoPersist.with_handler(Repo)` for in-memory operation.
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &__MODULE__.handle/3)
  end

  @doc false
  def handle(%EctoPersist.Insert{input: input, opts: _opts}, env, k) do
    changeset = extract_changeset(input)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)
      {:ok, stored} = InMemoryStore.insert(struct)
      k.(stored, env)
    else
      {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
    end
  end

  def handle(%EctoPersist.Update{input: input, opts: _opts}, env, k) do
    changeset = extract_changeset(input)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)
      {:ok, stored} = InMemoryStore.update(struct)
      k.(stored, env)
    else
      {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
    end
  end

  def handle(%EctoPersist.Upsert{input: input, opts: _opts}, env, k) do
    changeset = extract_changeset(input)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      result =
        if InMemoryStore.get(struct.id) do
          InMemoryStore.update(struct)
        else
          InMemoryStore.insert(struct)
        end

      {:ok, stored} = result
      k.(stored, env)
    else
      {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
    end
  end

  def handle(%EctoPersist.Delete{input: input, opts: _opts}, env, k) do
    struct = extract_struct(input)

    case InMemoryStore.delete(struct.id) do
      {:ok, deleted} -> k.({:ok, deleted}, env)
      {:error, reason} -> {%ThrowResult{error: {:delete_failed, reason}}, env}
    end
  end

  def handle(%EctoPersist.InsertAll{entries: entries, opts: opts}, env, k) do
    results =
      Enum.map(entries, fn entry ->
        changeset = extract_changeset(entry)

        if changeset.valid? do
          struct = Ecto.Changeset.apply_changes(changeset)
          InMemoryStore.insert(struct)
        else
          {:error, changeset}
        end
      end)

    successes =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, s} -> s end)

    if Keyword.get(opts, :returning, false) do
      k.({length(successes), successes}, env)
    else
      k.({length(successes), nil}, env)
    end
  end

  def handle(%EctoPersist.UpdateAll{entries: entries, opts: opts}, env, k) do
    # Check for query-based update
    case Keyword.get(opts, :query) do
      nil when entries == [] ->
        k.({0, nil}, env)

      nil ->
        # Update each entry individually
        results =
          Enum.map(entries, fn entry ->
            changeset = extract_changeset(entry)

            if changeset.valid? do
              struct = Ecto.Changeset.apply_changes(changeset)
              InMemoryStore.update(struct)
            else
              {:error, changeset}
            end
          end)

        successes =
          results
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, s} -> s end)

        if Keyword.get(opts, :returning, false) do
          k.({length(successes), successes}, env)
        else
          k.({length(successes), nil}, env)
        end

      _query ->
        # Query-based updates not supported in memory - return empty
        k.({0, nil}, env)
    end
  end

  def handle(%EctoPersist.UpsertAll{entries: entries, opts: opts}, env, k) do
    results =
      Enum.map(entries, fn entry ->
        changeset = extract_changeset(entry)

        if changeset.valid? do
          struct = Ecto.Changeset.apply_changes(changeset)

          if InMemoryStore.get(struct.id) do
            InMemoryStore.update(struct)
          else
            InMemoryStore.insert(struct)
          end
        else
          {:error, changeset}
        end
      end)

    successes =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, s} -> s end)

    if Keyword.get(opts, :returning, false) do
      k.({length(successes), successes}, env)
    else
      k.({length(successes), nil}, env)
    end
  end

  def handle(%EctoPersist.DeleteAll{entries: entries, opts: opts}, env, k) do
    results =
      Enum.map(entries, fn entry ->
        struct = extract_struct(entry)
        InMemoryStore.delete(struct.id)
      end)

    successes =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, s} -> s end)

    if Keyword.get(opts, :returning, false) do
      k.({length(successes), successes}, env)
    else
      k.({length(successes), nil}, env)
    end
  end

  # Extract changeset from various input types
  defp extract_changeset(%EctoPersist.EctoEvent{changeset: cs}), do: cs
  defp extract_changeset(%Ecto.Changeset{} = cs), do: cs

  defp extract_changeset(%{__struct__: _} = struct) do
    # Wrap struct in a changeset
    Ecto.Changeset.change(struct)
  end

  defp extract_changeset(map) when is_map(map) do
    # Can't create changeset from plain map without schema
    raise ArgumentError, "Plain maps not supported, use changeset or struct"
  end

  # Extract struct from various input types
  defp extract_struct(%EctoPersist.EctoEvent{changeset: cs}), do: Ecto.Changeset.apply_changes(cs)
  defp extract_struct(%Ecto.Changeset{} = cs), do: Ecto.Changeset.apply_changes(cs)
  defp extract_struct(%{__struct__: _} = struct), do: struct
end
