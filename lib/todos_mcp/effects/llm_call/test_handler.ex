defmodule TodosMcp.Effects.LlmCall.TestHandler do
  @moduledoc """
  Test handler for the LlmCall effect.

  Provides factory functions to create handlers that return canned responses,
  enabling deterministic testing of conversation computations.

  ## Usage

      alias TodosMcp.Effects.LlmCall
      alias TodosMcp.Effects.LlmCall.TestHandler

      # Simple text response
      comp
      |> LlmCall.with_handler(TestHandler.text_response("Hello!"))
      |> Comp.run()

      # Response sequence for tool flow testing
      comp
      |> LlmCall.with_handler(TestHandler.sequence([
        TestHandler.tool_use_response([%{id: "1", name: "create_todo", input: %{title: "Test"}}]),
        TestHandler.text_response("Done!")
      ]))
      |> Comp.run()
  """

  alias TodosMcp.Effects.LlmCall

  @doc """
  Create a handler that returns a fixed text response.

  ## Example

      handler = TestHandler.text_response("Hello, how can I help?")
  """
  @spec text_response(String.t()) :: LlmCall.handler_fn()
  def text_response(text) do
    fn %LlmCall.SendMessages{} ->
      %{
        text: text,
        needs_tools: false,
        tool_uses: [],
        raw: build_raw_response(text)
      }
    end
  end

  @doc """
  Create a handler that returns a tool use response.

  The LLM is requesting tool execution. The response should contain
  tool use blocks with id, name, and input.

  ## Example

      handler = TestHandler.tool_use_response([
        %{id: "toolu_123", name: "create_todo", input: %{"title" => "Buy milk"}}
      ])
  """
  @spec tool_use_response([map()]) :: LlmCall.handler_fn()
  def tool_use_response(tool_uses) do
    fn %LlmCall.SendMessages{} ->
      %{
        text: "",
        needs_tools: true,
        tool_uses: normalize_tool_uses(tool_uses),
        raw: build_raw_tool_response(tool_uses)
      }
    end
  end

  @doc """
  Create a handler that returns an error.

  ## Example

      handler = TestHandler.error_response(:rate_limited)
  """
  @spec error_response(term()) :: LlmCall.handler_fn()
  def error_response(reason) do
    fn %LlmCall.SendMessages{} ->
      {:error, reason}
    end
  end

  @doc """
  Create a handler that returns responses in sequence.

  Each call consumes the next response. Raises if called more times
  than responses available.

  ## Example

      handler = TestHandler.sequence([
        TestHandler.tool_use_response([%{id: "1", name: "list_todos", input: %{}}]),
        TestHandler.text_response("Here are your todos...")
      ])

  Note: The sequence items should be handler functions, not raw responses.
  """
  @spec sequence([LlmCall.handler_fn()]) :: LlmCall.handler_fn()
  def sequence(handlers) when is_list(handlers) do
    # Use process dictionary to track state (works across Skuld handler calls)
    ref = make_ref()
    Process.put({__MODULE__, ref}, handlers)

    fn %LlmCall.SendMessages{} = request ->
      case Process.get({__MODULE__, ref}) do
        [handler | rest] ->
          Process.put({__MODULE__, ref}, rest)
          handler.(request)

        [] ->
          raise "TestHandler.sequence exhausted: no more responses available"
      end
    end
  end

  @doc """
  Create a handler from a list of raw response maps.

  Convenience function when you want to specify responses directly
  rather than using helper functions.

  ## Example

      handler = TestHandler.from_responses([
        %{text: "First response", needs_tools: false, tool_uses: []},
        %{text: "Second response", needs_tools: false, tool_uses: []}
      ])
  """
  @spec from_responses([map()]) :: LlmCall.handler_fn()
  def from_responses(responses) when is_list(responses) do
    ref = make_ref()
    Process.put({__MODULE__, ref}, responses)

    fn %LlmCall.SendMessages{} ->
      case Process.get({__MODULE__, ref}) do
        [response | rest] ->
          Process.put({__MODULE__, ref}, rest)
          ensure_raw(response)

        [] ->
          raise "TestHandler.from_responses exhausted: no more responses available"
      end
    end
  end

  @doc """
  Create a handler that echoes back the last user message.

  Useful for basic integration testing.
  """
  @spec echo_handler() :: LlmCall.handler_fn()
  def echo_handler do
    fn %LlmCall.SendMessages{messages: messages} ->
      last_user_message =
        messages
        |> Enum.reverse()
        |> Enum.find(fn msg -> msg[:role] == "user" || msg["role"] == "user" end)

      text =
        case last_user_message do
          %{content: content} when is_binary(content) -> "Echo: #{content}"
          %{"content" => content} when is_binary(content) -> "Echo: #{content}"
          _ -> "Echo: (no user message)"
        end

      %{
        text: text,
        needs_tools: false,
        tool_uses: [],
        raw: build_raw_response(text)
      }
    end
  end

  @doc """
  Create a handler that records all requests for later inspection.

  Returns a handler and a function to retrieve recorded requests.

  ## Example

      {handler, get_requests} = TestHandler.recording_handler(
        TestHandler.text_response("OK")
      )

      # ... run computation ...

      requests = get_requests.()
      assert length(requests) == 2
  """
  @spec recording_handler(LlmCall.handler_fn()) ::
          {LlmCall.handler_fn(), (-> [LlmCall.SendMessages.t()])}
  def recording_handler(inner_handler) do
    ref = make_ref()
    Process.put({__MODULE__, :recording, ref}, [])

    handler = fn %LlmCall.SendMessages{} = request ->
      requests = Process.get({__MODULE__, :recording, ref}, [])
      Process.put({__MODULE__, :recording, ref}, requests ++ [request])
      inner_handler.(request)
    end

    get_requests = fn ->
      Process.get({__MODULE__, :recording, ref}, [])
    end

    {handler, get_requests}
  end

  # Private helpers

  defp normalize_tool_uses(tool_uses) do
    Enum.map(tool_uses, fn tool_use ->
      %{
        id: tool_use[:id] || tool_use["id"] || generate_tool_id(),
        name: tool_use[:name] || tool_use["name"],
        input: tool_use[:input] || tool_use["input"] || %{}
      }
    end)
  end

  defp generate_tool_id do
    "toolu_test_#{:erlang.unique_integer([:positive])}"
  end

  defp build_raw_response(text) do
    %{
      "id" => "msg_test_#{:erlang.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "model" => "claude-test",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end

  defp build_raw_tool_response(tool_uses) do
    content =
      Enum.map(tool_uses, fn tool_use ->
        %{
          "type" => "tool_use",
          "id" => tool_use[:id] || tool_use["id"] || generate_tool_id(),
          "name" => tool_use[:name] || tool_use["name"],
          "input" => tool_use[:input] || tool_use["input"] || %{}
        }
      end)

    %{
      "id" => "msg_test_#{:erlang.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "content" => content,
      "stop_reason" => "tool_use",
      "model" => "claude-test",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end

  defp ensure_raw(%{raw: _} = response), do: response

  defp ensure_raw(response) do
    Map.put(response, :raw, build_raw_response(response[:text] || ""))
  end
end
