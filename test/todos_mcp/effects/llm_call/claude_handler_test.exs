defmodule TodosMcp.Effects.LlmCall.ClaudeHandlerTest do
  use ExUnit.Case, async: true

  alias TodosMcp.Effects.LlmCall.ClaudeHandler

  describe "normalize_response/1" do
    test "normalizes a text-only response" do
      claude_response = %{
        id: "msg_123",
        model: "claude-sonnet-4-20250514",
        role: "assistant",
        content: [%{"type" => "text", "text" => "Hello there!"}],
        stop_reason: "end_turn",
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      result = ClaudeHandler.normalize_response(claude_response)

      assert result.text == "Hello there!"
      assert result.tool_uses == []
      assert result.needs_tools == false
      assert result.raw == claude_response
    end

    test "normalizes a response with tool use" do
      claude_response = %{
        id: "msg_456",
        model: "claude-sonnet-4-20250514",
        role: "assistant",
        content: [
          %{"type" => "text", "text" => "I'll create that todo for you."},
          %{
            "type" => "tool_use",
            "id" => "tool_abc",
            "name" => "create_todo",
            "input" => %{"title" => "Buy milk", "priority" => "high"}
          }
        ],
        stop_reason: "tool_use",
        usage: %{input_tokens: 20, output_tokens: 15}
      }

      result = ClaudeHandler.normalize_response(claude_response)

      assert result.text == "I'll create that todo for you."
      assert result.needs_tools == true
      assert length(result.tool_uses) == 1

      [tool_use] = result.tool_uses
      assert tool_use.id == "tool_abc"
      assert tool_use.name == "create_todo"
      assert tool_use.input == %{"title" => "Buy milk", "priority" => "high"}
    end

    test "normalizes multiple tool uses" do
      claude_response = %{
        id: "msg_789",
        model: "claude-sonnet-4-20250514",
        role: "assistant",
        content: [
          %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "create_todo",
            "input" => %{"title" => "First"}
          },
          %{
            "type" => "tool_use",
            "id" => "t2",
            "name" => "create_todo",
            "input" => %{"title" => "Second"}
          }
        ],
        stop_reason: "tool_use",
        usage: %{input_tokens: 30, output_tokens: 25}
      }

      result = ClaudeHandler.normalize_response(claude_response)

      assert result.needs_tools == true
      assert length(result.tool_uses) == 2

      names = Enum.map(result.tool_uses, & &1.name)
      assert names == ["create_todo", "create_todo"]

      ids = Enum.map(result.tool_uses, & &1.id)
      assert ids == ["t1", "t2"]
    end

    test "handles atom keys in tool_use" do
      claude_response = %{
        id: "msg_atom",
        model: "claude-sonnet-4-20250514",
        role: "assistant",
        content: [
          %{type: "tool_use", id: "t1", name: "list_todos", input: %{}}
        ],
        stop_reason: "tool_use",
        usage: %{input_tokens: 5, output_tokens: 10}
      }

      result = ClaudeHandler.normalize_response(claude_response)

      [tool_use] = result.tool_uses
      assert tool_use.id == "t1"
      assert tool_use.name == "list_todos"
      assert tool_use.input == %{}
    end
  end

  describe "handler/1" do
    test "creates a handler function" do
      handler = ClaudeHandler.handler(api_key: "test-key")
      assert is_function(handler, 1)
    end

    test "handler merges base config with call opts" do
      # We can't easily test the actual API call without mocking,
      # but we can verify the handler is created correctly
      handler = ClaudeHandler.handler(api_key: "base-key", model: "base-model")

      # The handler should be a function that accepts SendMessages
      assert is_function(handler, 1)
    end
  end
end
