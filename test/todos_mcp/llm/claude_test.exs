defmodule TodosMcp.Llm.ClaudeTest do
  use ExUnit.Case, async: true

  alias TodosMcp.Llm.Claude
  alias TodosMcp.Mcp.Tools

  describe "convert_tools/1" do
    test "converts MCP tools to Claude format" do
      mcp_tools = [
        %{
          name: "create_todo",
          description: "Create a new todo",
          inputSchema: %{
            type: "object",
            properties: %{title: %{type: "string"}},
            required: ["title"]
          }
        }
      ]

      claude_tools = Claude.convert_tools(mcp_tools)

      assert [tool] = claude_tools
      assert tool.name == "create_todo"
      assert tool.description == "Create a new todo"
      # Claude uses input_schema (snake_case)
      assert tool.input_schema == %{
               type: "object",
               properties: %{title: %{type: "string"}},
               required: ["title"]
             }
    end

    test "converts all MCP tools from Tools module" do
      mcp_tools = Tools.all()
      claude_tools = Claude.convert_tools(mcp_tools)

      assert length(claude_tools) == length(mcp_tools)

      Enum.each(claude_tools, fn tool ->
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :input_schema)
      end)
    end
  end

  describe "tool_result_message/2" do
    test "creates tool result message from ok tuple" do
      result = Claude.tool_result_message("tool_123", {:ok, %{id: "abc", title: "Test"}})

      assert result.role == "user"
      assert [content_block] = result.content
      assert content_block.type == "tool_result"
      assert content_block.tool_use_id == "tool_123"
      # Should be JSON-encoded
      assert is_binary(content_block.content)
    end

    test "creates tool result message from error tuple" do
      result = Claude.tool_result_message("tool_123", {:error, "Not found"})

      assert result.role == "user"
      assert [content_block] = result.content
      assert content_block.content =~ "Error:"
    end

    test "creates tool result message from plain value" do
      result = Claude.tool_result_message("tool_123", "plain text result")

      assert result.role == "user"
      assert [content_block] = result.content
      assert content_block.content == "plain text result"
    end
  end

  describe "assistant_message/1" do
    test "creates assistant message from response" do
      response = %{
        id: "msg_123",
        model: "claude-sonnet-4-20250514",
        role: "assistant",
        content: [%{"type" => "text", "text" => "Hello!"}],
        stop_reason: "end_turn",
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      message = Claude.assistant_message(response)

      assert message.role == "assistant"
      assert message.content == [%{"type" => "text", "text" => "Hello!"}]
    end
  end

  describe "extract_text/1" do
    test "extracts text from response with string keys" do
      response = %{
        content: [
          %{"type" => "text", "text" => "Hello "},
          %{"type" => "text", "text" => "World"}
        ]
      }

      assert Claude.extract_text(response) == "Hello \nWorld"
    end

    test "extracts text from response with atom keys" do
      response = %{
        content: [
          %{type: "text", text: "Hello"},
          %{type: "tool_use", id: "123", name: "test", input: %{}}
        ]
      }

      assert Claude.extract_text(response) == "Hello"
    end

    test "returns empty string when no text blocks" do
      response = %{
        content: [
          %{type: "tool_use", id: "123", name: "test", input: %{}}
        ]
      }

      assert Claude.extract_text(response) == ""
    end
  end

  describe "extract_tool_uses/1" do
    test "extracts tool use blocks with string keys" do
      response = %{
        content: [
          %{"type" => "text", "text" => "Let me help"},
          %{
            "type" => "tool_use",
            "id" => "tool_1",
            "name" => "create_todo",
            "input" => %{"title" => "Test"}
          }
        ]
      }

      tool_uses = Claude.extract_tool_uses(response)

      assert [tool_use] = tool_uses
      assert tool_use["name"] == "create_todo"
      assert tool_use["id"] == "tool_1"
    end

    test "extracts multiple tool use blocks" do
      response = %{
        content: [
          %{type: "tool_use", id: "tool_1", name: "create_todo", input: %{}},
          %{type: "tool_use", id: "tool_2", name: "list_todos", input: %{}}
        ]
      }

      tool_uses = Claude.extract_tool_uses(response)
      assert length(tool_uses) == 2
    end
  end

  describe "needs_tool_execution?/1" do
    test "returns true when stop_reason is tool_use" do
      response = %{stop_reason: "tool_use"}
      assert Claude.needs_tool_execution?(response)
    end

    test "returns false when stop_reason is end_turn" do
      response = %{stop_reason: "end_turn"}
      refute Claude.needs_tool_execution?(response)
    end

    test "returns false when stop_reason is nil" do
      response = %{stop_reason: nil}
      refute Claude.needs_tool_execution?(response)
    end
  end
end
