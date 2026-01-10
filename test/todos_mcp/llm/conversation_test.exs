defmodule TodosMcp.Llm.ConversationTest do
  use ExUnit.Case, async: true

  alias TodosMcp.Llm.Conversation

  describe "new/1" do
    test "creates conversation with required api_key" do
      conv = Conversation.new(api_key: "test-key")

      assert conv.api_key == "test-key"
      assert conv.messages == []
      assert length(conv.tools) > 0
      assert is_binary(conv.system_prompt)
    end

    test "accepts custom system_prompt" do
      conv = Conversation.new(api_key: "test-key", system_prompt: "Custom prompt")

      assert conv.system_prompt == "Custom prompt"
    end

    test "accepts custom model" do
      conv = Conversation.new(api_key: "test-key", model: "claude-3-opus")

      assert conv.model == "claude-3-opus"
    end

    test "raises if api_key is missing" do
      assert_raise KeyError, fn ->
        Conversation.new([])
      end
    end

    test "tools are in Claude format" do
      conv = Conversation.new(api_key: "test-key")

      Enum.each(conv.tools, fn tool ->
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        # Claude format uses input_schema (not inputSchema)
        assert Map.has_key?(tool, :input_schema)
      end)
    end
  end

  describe "clear_history/1" do
    test "clears messages but keeps configuration" do
      conv =
        Conversation.new(api_key: "test-key", system_prompt: "Custom")
        |> Map.put(:messages, [%{role: "user", content: "test"}])

      cleared = Conversation.clear_history(conv)

      assert cleared.messages == []
      assert cleared.api_key == "test-key"
      assert cleared.system_prompt == "Custom"
      assert length(cleared.tools) > 0
    end
  end

  describe "message_count/1" do
    test "returns 0 for new conversation" do
      conv = Conversation.new(api_key: "test-key")
      assert Conversation.message_count(conv) == 0
    end

    test "returns correct count" do
      conv =
        Conversation.new(api_key: "test-key")
        |> Map.put(:messages, [
          %{role: "user", content: "hi"},
          %{role: "assistant", content: "hello"}
        ])

      assert Conversation.message_count(conv) == 2
    end
  end
end
