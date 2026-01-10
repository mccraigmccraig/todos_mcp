defmodule TodosMcp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    storage_mode = Application.get_env(:todos_mcp, :storage_mode, :in_memory)

    children =
      [
        TodosMcpWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:todos_mcp, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: TodosMcp.PubSub}
      ] ++
        storage_children(storage_mode) ++
        [
          # Start to serve requests, typically the last entry
          TodosMcpWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TodosMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Storage-specific children based on mode
  defp storage_children(:database) do
    [TodosMcp.Repo]
  end

  defp storage_children(:in_memory) do
    [TodosMcp.InMemoryStore]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TodosMcpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
