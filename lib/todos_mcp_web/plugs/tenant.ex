defmodule TodosMcpWeb.Plugs.Tenant do
  @moduledoc """
  Plug to manage tenant identification via cookie.

  Creates a UUID v7 tenant_id if one doesn't exist, stores it in a cookie,
  and puts it in the session for LiveView access.

  ## Cookie Configuration

  - Name: `tenant_id`
  - Max age: 10 years (effectively permanent)
  - HTTP only: true
  - Same site: lax
  """

  import Plug.Conn

  @cookie_name "tenant_id"
  # 10 years
  @cookie_max_age 60 * 60 * 24 * 365 * 10

  def init(opts), do: opts

  def call(conn, _opts) do
    tenant_id = get_or_create_tenant_id(conn)

    conn
    |> put_tenant_cookie(tenant_id)
    |> put_session("tenant_id", tenant_id)
  end

  defp get_or_create_tenant_id(conn) do
    case conn.cookies[@cookie_name] do
      nil -> generate_tenant_id()
      "" -> generate_tenant_id()
      tenant_id -> tenant_id
    end
  end

  defp generate_tenant_id do
    Uniq.UUID.uuid7()
  end

  defp put_tenant_cookie(conn, tenant_id) do
    put_resp_cookie(conn, @cookie_name, tenant_id,
      max_age: @cookie_max_age,
      http_only: true,
      same_site: "Lax"
    )
  end
end
