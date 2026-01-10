defmodule TodosMcp.Effects.LlmCallTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias TodosMcp.Effects.LlmCall

  describe "send_messages/2" do
    test "creates a computation that invokes the handler" do
      messages = [%{role: "user", content: "Hello"}]

      handler = fn %LlmCall.SendMessages{messages: msgs, opts: opts} ->
        assert msgs == messages
        assert opts == [tools: [:test_tool]]

        %{
          text: "Hi there!",
          tool_uses: [],
          needs_tools: false,
          raw: %{model: "test"}
        }
      end

      result =
        comp do
          response <- LlmCall.send_messages(messages, tools: [:test_tool])
          response
        end
        |> LlmCall.with_handler(handler)
        |> Comp.run!()

      assert result.text == "Hi there!"
      assert result.needs_tools == false
      assert result.raw == %{model: "test"}
    end

    test "handles tool_use responses" do
      messages = [%{role: "user", content: "Create a todo"}]

      handler = fn %LlmCall.SendMessages{} ->
        %{
          text: "",
          tool_uses: [
            %{id: "tool_1", name: "create_todo", input: %{"title" => "Test"}}
          ],
          needs_tools: true,
          raw: %{}
        }
      end

      result =
        comp do
          response <- LlmCall.send_messages(messages)
          response
        end
        |> LlmCall.with_handler(handler)
        |> Comp.run!()

      assert result.needs_tools == true
      assert length(result.tool_uses) == 1
      assert hd(result.tool_uses).name == "create_todo"
    end

    test "handles errors from handler" do
      handler = fn %LlmCall.SendMessages{} ->
        {:error, {:api_error, 401, "Unauthorized"}}
      end

      result =
        comp do
          response <- LlmCall.send_messages([])
          response
        end
        |> LlmCall.with_handler(handler)
        |> Comp.run!()

      assert result == {:error, {:api_error, 401, "Unauthorized"}}
    end

    test "supports multiple LLM calls in sequence" do
      call_count = :counters.new(1, [:atomics])

      handler = fn %LlmCall.SendMessages{messages: msgs} ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        %{
          text: "Response #{count} (#{length(msgs)} messages)",
          tool_uses: [],
          needs_tools: false,
          raw: %{}
        }
      end

      result =
        comp do
          r1 <- LlmCall.send_messages([%{role: "user", content: "First"}])
          r2 <- LlmCall.send_messages([%{role: "user", content: "Second"}])
          {r1.text, r2.text}
        end
        |> LlmCall.with_handler(handler)
        |> Comp.run!()

      assert result == {"Response 1 (1 messages)", "Response 2 (1 messages)"}
    end
  end

  describe "with_handler/2" do
    test "handler receives operation struct with all fields" do
      received = :ets.new(:received, [:set, :public])

      handler = fn op ->
        :ets.insert(received, {:op, op})
        %{text: "ok", tool_uses: [], needs_tools: false, raw: %{}}
      end

      comp do
        _ <- LlmCall.send_messages([%{role: "user", content: "test"}], system: "Be helpful")
        :done
      end
      |> LlmCall.with_handler(handler)
      |> Comp.run!()

      [{:op, op}] = :ets.lookup(received, :op)
      assert %LlmCall.SendMessages{} = op
      assert op.messages == [%{role: "user", content: "test"}]
      assert op.opts == [system: "Be helpful"]
    end
  end
end
