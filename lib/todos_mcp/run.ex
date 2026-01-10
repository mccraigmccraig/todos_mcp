defmodule TodosMcp.Run do
  @moduledoc """
  Runs domain operations through the Skuld effect handler stack.

  Sets up the layered handler chain:
  - Command effect → DomainHandler (business logic)
  - Query effect → DataAccess.Impl (data access)
  - EctoPersist effect → Repo (persistence)
  - Throw effect → error handling

  ## Example

      alias TodosMcp.Run
      alias TodosMcp.Commands.CreateTodo

      case Run.execute(%CreateTodo{title: "Buy milk"}) do
        {:ok, todo} -> # success
        {:error, reason} -> # failure
      end
  """

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.{Command, Query, EctoPersist, Throw}
  alias TodosMcp.{Repo, DomainHandler, DataAccess}

  @doc """
  Execute a domain operation (command or query).

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec execute(struct()) :: {:ok, term()} | {:error, term()}
  def execute(operation) do
    comp do
      result <- Command.execute(operation)
      result
    end
    |> Command.with_handler(&DomainHandler.handle/1)
    |> Query.with_handler(%{DataAccess.Impl => :direct})
    |> EctoPersist.with_handler(Repo)
    |> Throw.with_handler()
    |> Comp.run()
    |> extract_result()
  end

  defp extract_result({result, _env}) do
    case result do
      %Skuld.Comp.Throw{error: error} -> {:error, error}
      other -> other
    end
  end
end
