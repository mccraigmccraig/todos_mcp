defmodule TodosMcp.Effects.LlmCall.ClaudeHandler do
  @moduledoc """
  Claude handler for the LlmCall effect.

  Wraps the existing `TodosMcp.Llm.Claude` HTTP client to provide
  a handler function for the LlmCall effect.

  ## Usage

      alias TodosMcp.Effects.LlmCall
      alias TodosMcp.Effects.LlmCall.ClaudeHandler

      my_computation
      |> LlmCall.with_handler(ClaudeHandler.handler(
        api_key: "sk-ant-...",
        system: "You are a helpful assistant",
        tools: my_tools
      ))
      |> Comp.run()

  ## Configuration

  - `:api_key` - Required. Anthropic API key.
  - `:system` - System prompt (optional).
  - `:tools` - Tool definitions in Claude format (optional).
  - `:model` - Model to use (optional, defaults to Claude's default).
  - `:max_tokens` - Maximum tokens in response (optional).

  Configuration can be provided at handler creation time (base config)
  and/or at call time via opts. Call-time opts override base config.
  """

  alias TodosMcp.Llm.Claude
  alias TodosMcp.Effects.LlmCall

  @doc """
  Create a handler function for the LlmCall effect using Claude.

  ## Options

  All options are passed to `Claude.send_messages/2`. Common options:

  - `:api_key` - Required. Anthropic API key.
  - `:system` - System prompt.
  - `:tools` - Tool definitions (Claude format).
  - `:model` - Model to use.
  - `:max_tokens` - Max response tokens.

  ## Returns

  A handler function suitable for `LlmCall.with_handler/2`.
  """
  @spec handler(keyword()) :: LlmCall.handler_fn()
  def handler(base_config \\ []) do
    fn %LlmCall.SendMessages{messages: messages, opts: call_opts} ->
      # Merge base config with call-time opts (call opts take precedence)
      merged_opts = Keyword.merge(base_config, call_opts)

      case Claude.send_messages(messages, merged_opts) do
        {:ok, response} ->
          normalize_response(response)

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Normalize a Claude response to the LlmCall response format.

  ## Response Format

      %{
        text: String.t(),
        tool_uses: [%{id: String.t(), name: String.t(), input: map()}],
        needs_tools: boolean(),
        raw: map()
      }
  """
  @spec normalize_response(Claude.response()) :: LlmCall.response()
  def normalize_response(response) do
    %{
      text: Claude.extract_text(response),
      tool_uses: normalize_tool_uses(Claude.extract_tool_uses(response)),
      needs_tools: Claude.needs_tool_execution?(response),
      provider: :claude,
      raw: response
    }
  end

  # Normalize tool uses to have consistent atom keys
  defp normalize_tool_uses(tool_uses) do
    Enum.map(tool_uses, fn tool_use ->
      %{
        id: tool_use["id"] || tool_use[:id],
        name: tool_use["name"] || tool_use[:name],
        input: tool_use["input"] || tool_use[:input] || %{}
      }
    end)
  end
end
