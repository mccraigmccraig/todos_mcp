defmodule TodosMcp.CommandContext do
  @moduledoc """
  Context for command/query execution.

  Provides tenant isolation and other cross-cutting concerns via the Reader effect.

  ## Usage

  In domain handlers, access the context via Reader:

      use Skuld.Syntax
      alias Skuld.Effects.Reader
      alias TodosMcp.CommandContext

      defcomp handle(%CreateTodo{} = cmd) do
        ctx <- Reader.ask(CommandContext)
        # use ctx.tenant_id
      end

  When executing commands, install the context:

      comp
      |> Reader.with_handler(%CommandContext{tenant_id: "tenant-123"}, tag: CommandContext)
      |> Comp.run!()
  """

  @derive Jason.Encoder
  defstruct [:tenant_id]

  @type t :: %__MODULE__{
          tenant_id: String.t()
        }

  @doc "Create a new command context"
  @spec new(String.t()) :: t()
  def new(tenant_id) when is_binary(tenant_id) do
    %__MODULE__{tenant_id: tenant_id}
  end
end
