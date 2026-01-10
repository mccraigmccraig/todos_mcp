defmodule TodosMcpWeb.SettingsController do
  @moduledoc """
  Controller for managing user settings stored in session.
  """
  use TodosMcpWeb, :controller

  @doc """
  Save API keys to session and redirect back to home.
  Handles both Anthropic and Groq API keys.
  """
  def save_api_key(conn, params) do
    conn = maybe_save_key(conn, "api_key", params["api_key"])
    conn = maybe_save_key(conn, "groq_api_key", params["groq_api_key"])

    # Determine flash message based on what was saved
    has_anthropic = params["api_key"] && params["api_key"] != ""
    has_groq = params["groq_api_key"] && params["groq_api_key"] != ""

    message =
      case {has_anthropic, has_groq} do
        {true, true} -> "API keys saved"
        {true, false} -> "Anthropic API key saved"
        {false, true} -> "Groq API key saved"
        {false, false} -> "No changes made"
      end

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/")
  end

  defp maybe_save_key(conn, _key_name, nil), do: conn
  defp maybe_save_key(conn, _key_name, ""), do: conn
  defp maybe_save_key(conn, key_name, value), do: put_session(conn, key_name, value)

  @doc """
  Clear API keys from session and redirect back to home.
  """
  def clear_api_key(conn, _params) do
    conn
    |> delete_session("api_key")
    |> delete_session("groq_api_key")
    |> put_flash(:info, "API keys cleared")
    |> redirect(to: ~p"/")
  end
end
