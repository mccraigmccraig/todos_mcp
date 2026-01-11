defmodule TodosMcp.Effects.LlmCall.GeminiHandler do
  @moduledoc """
  Gemini handler for the LlmCall effect.

  Wraps the `TodosMcp.Llm.Gemini` HTTP client to provide
  a handler function for the LlmCall effect.

  ## Usage

      alias TodosMcp.Effects.LlmCall
      alias TodosMcp.Effects.LlmCall.GeminiHandler

      my_computation
      |> LlmCall.with_handler(GeminiHandler.handler(
        api_key: "your-google-ai-key",
        system: "You are a helpful assistant",
        tools: my_tools
      ))
      |> Comp.run()

  ## Configuration

  - `:api_key` - Required. Google AI API key.
  - `:system` - System instruction (optional).
  - `:tools` - Tool definitions in MCP/Claude format (will be converted).
  - `:model` - Model to use (optional, defaults to gemini-2.0-flash).

  Configuration can be provided at handler creation time (base config)
  and/or at call time via opts. Call-time opts override base config.
  """

  alias TodosMcp.Llm.Gemini
  alias TodosMcp.Effects.LlmCall

  @doc """
  Create a handler function for the LlmCall effect using Gemini.

  ## Options

  - `:api_key` - Required. Google AI API key.
  - `:system` - System instruction.
  - `:tools` - Tool definitions (MCP/Claude format, will be converted).
  - `:model` - Model to use.

  ## Returns

  A handler function suitable for `LlmCall.with_handler/2`.
  """
  @spec handler(keyword()) :: LlmCall.handler_fn()
  def handler(base_config \\ []) do
    fn %LlmCall.SendMessages{messages: messages, opts: call_opts} ->
      # Merge base config with call-time opts (call opts take precedence)
      merged_opts = Keyword.merge(base_config, call_opts)

      # Convert tools from MCP/Claude format to Gemini format
      tools =
        case Keyword.get(merged_opts, :tools, []) do
          [] -> []
          tools -> Gemini.convert_tools(tools)
        end

      gemini_opts = Keyword.put(merged_opts, :tools, tools)

      case Gemini.send_messages(messages, gemini_opts) do
        {:ok, response} ->
          normalize_response(response)

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Normalize a Gemini response to the LlmCall response format.

  ## Response Format

      %{
        text: String.t(),
        tool_uses: [%{id: String.t(), name: String.t(), input: map()}],
        needs_tools: boolean(),
        raw: map()
      }
  """
  @spec normalize_response(Gemini.response()) :: LlmCall.response()
  def normalize_response(response) do
    function_calls = Gemini.extract_function_calls(response)

    %{
      text: Gemini.extract_text(response),
      tool_uses: normalize_function_calls(function_calls),
      needs_tools: function_calls != [],
      raw: build_raw_response(response)
    }
  end

  # Convert Gemini function calls to LlmCall tool_use format
  # Gemini doesn't provide IDs, so we generate them
  defp normalize_function_calls(function_calls) do
    function_calls
    |> Enum.with_index()
    |> Enum.map(fn {fc, idx} ->
      %{
        id: "gemini_fc_#{idx}_#{:erlang.unique_integer([:positive])}",
        name: fc.name,
        input: fc.args
      }
    end)
  end

  # Build a raw response that mimics Claude's format for compatibility
  # with ConversationComp.assistant_message/1
  defp build_raw_response(response) do
    parts = Gemini.assistant_parts(response)

    content =
      Enum.map(parts, fn part ->
        cond do
          Map.has_key?(part, :text) ->
            %{"type" => "text", "text" => part.text}

          Map.has_key?(part, :functionCall) ->
            fc = part.functionCall

            %{
              "type" => "tool_use",
              "id" => "gemini_fc_#{:erlang.unique_integer([:positive])}",
              "name" => fc.name,
              "input" => fc.args
            }

          true ->
            %{"type" => "unknown", "data" => part}
        end
      end)

    %{"content" => content}
  end
end
