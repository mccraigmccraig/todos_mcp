defmodule TodosMcpWeb.PageController do
  use TodosMcpWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
