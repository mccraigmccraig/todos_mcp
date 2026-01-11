defmodule TodosMcp.Effects.LlmCall.GroqHandler do
  @moduledoc """
  Groq handler for the LlmCall effect.

  Wraps the `TodosMcp.Llm.Groq` HTTP client to provide
  a handler function for the LlmCall effect.

  Groq provides fast inference with a generous free tier,
  using OpenAI-compatible API with function calling support.

  ## Usage

      alias TodosMcp.Effects.LlmCall
      alias TodosMcp.Effects.LlmCall.GroqHandler

      my_computation
      |> LlmCall.with_handler(GroqHandler.handler(
        api_key: "your-groq-key",
        system: "You are a helpful assistant",
        tools: my_tools
      ))
      |> Comp.run()

  ## Configuration

  - `:api_key` - Required. Groq API key.
  - `:system` - System instruction (optional).
  - `:tools` - Tool definitions in MCP/Claude format (will be converted).
  - `:model` - Model to use (optional, defaults to llama-3.3-70b-versatile).

  Configuration can be provided at handler creation time (base config)
  and/or at call time via opts. Call-time opts override base config.
  """

  alias TodosMcp.Llm.Groq
  alias TodosMcp.Effects.LlmCall

  @doc """
  Create a handler function for the LlmCall effect using Groq.

  ## Options

  - `:api_key` - Required. Groq API key.
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

      # Convert tools from MCP/Claude format to OpenAI format
      tools =
        case Keyword.get(merged_opts, :tools, []) do
          [] -> []
          tools -> Groq.convert_tools(tools)
        end

      groq_opts = Keyword.put(merged_opts, :tools, tools)

      result = Groq.send_messages(messages, groq_opts)
      IO.inspect(result, label: "GroqHandler send_messages result", limit: :infinity)

      case result do
        {:ok, response} ->
          normalized = normalize_response(response)
          IO.inspect(normalized, label: "GroqHandler normalized response")
          normalized

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Normalize a Groq response to the LlmCall response format.

  ## Response Format

      %{
        text: String.t(),
        tool_uses: [%{id: String.t(), name: String.t(), input: map()}],
        needs_tools: boolean(),
        raw: map()
      }
  """
  @spec normalize_response(Groq.response()) :: LlmCall.response()
  def normalize_response(response) do
    tool_calls = Groq.extract_tool_calls(response)

    %{
      text: Groq.extract_text(response),
      tool_uses: normalize_tool_calls(tool_calls),
      needs_tools: tool_calls != [],
      provider: :groq,
      raw: build_raw_response(response)
    }
  end

  # Convert OpenAI tool calls to LlmCall tool_use format
  defp normalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      args =
        case Jason.decode(tc.function.arguments) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      %{
        id: tc.id,
        name: tc.function.name,
        input: args
      }
    end)
  end

  # Build a raw response that mimics Claude's format for compatibility
  # with ConversationComp.assistant_message/1
  defp build_raw_response(response) do
    msg = Groq.assistant_message(response)
    tool_calls = Groq.extract_tool_calls(response)

    content =
      []
      |> maybe_add_text(msg[:content] || msg["content"])
      |> maybe_add_tool_uses(tool_calls)

    %{"content" => content}
  end

  defp maybe_add_text(content, nil), do: content
  defp maybe_add_text(content, ""), do: content
  defp maybe_add_text(content, text), do: content ++ [%{"type" => "text", "text" => text}]

  defp maybe_add_tool_uses(content, []), do: content

  defp maybe_add_tool_uses(content, tool_calls) do
    tool_use_blocks =
      Enum.map(tool_calls, fn tc ->
        args =
          case Jason.decode(tc.function.arguments) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        %{
          "type" => "tool_use",
          "id" => tc.id,
          "name" => tc.function.name,
          "input" => args
        }
      end)

    content ++ tool_use_blocks
  end
end
