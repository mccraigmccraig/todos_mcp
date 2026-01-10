ExUnit.start()

# Only set up Ecto sandbox if using database storage mode
if Application.get_env(:todos_mcp, :storage_mode, :in_memory) == :database do
  Ecto.Adapters.SQL.Sandbox.mode(TodosMcp.Repo, :manual)
end
