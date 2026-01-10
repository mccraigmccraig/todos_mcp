defmodule TodosMcpWeb.SettingsController do
  @moduledoc """
  Controller for managing user settings stored in session.
  """
  use TodosMcpWeb, :controller

  @doc """
  Save the API key to session and redirect back to home.
  """
  def save_api_key(conn, %{"api_key" => api_key}) when api_key != "" do
    conn
    |> put_session(:api_key, api_key)
    |> put_flash(:info, "API key saved")
    |> redirect(to: ~p"/")
  end

  def save_api_key(conn, _params) do
    conn
    |> put_flash(:error, "API key cannot be empty")
    |> redirect(to: ~p"/")
  end

  @doc """
  Clear the API key from session and redirect back to home.
  """
  def clear_api_key(conn, _params) do
    conn
    |> delete_session(:api_key)
    |> put_flash(:info, "API key cleared")
    |> redirect(to: ~p"/")
  end
end
