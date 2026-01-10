defmodule TodosMcp.Repo do
  use Ecto.Repo,
    otp_app: :todos_mcp,
    adapter: Ecto.Adapters.Postgres
end
