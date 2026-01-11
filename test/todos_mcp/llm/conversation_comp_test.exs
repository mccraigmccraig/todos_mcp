defmodule TodosMcp.Llm.ConversationCompTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Suspend
  alias Skuld.Effects.{EffectLogger, State, Yield, Throw}
  alias TodosMcp.Llm.ConversationComp
  alias TodosMcp.Effects.LlmCall
  alias TodosMcp.Effects.LlmCall.TestHandler

  # Helper to build computation with all handlers
  defp build_comp(state, llm_handler) do
    ConversationComp.run()
    |> State.with_handler(state, tag: ConversationComp)
    |> EffectLogger.with_logging()
    |> LlmCall.with_handler(llm_handler)
    |> Yield.with_handler()
    |> Throw.with_handler()
  end

  describe "run/0 yields protocol" do
    test "first yield is :await_user_input" do
      state = ConversationComp.initial_state()
      comp = build_comp(state, TestHandler.text_response("Hello!"))

      {result, _env} = Comp.run(comp)

      assert %Suspend{value: :await_user_input} = result
    end

    test "simple text response flow" do
      state = ConversationComp.initial_state()
      comp = build_comp(state, TestHandler.text_response("Hello back!"))

      # Step 1: Get :await_user_input
      {%Suspend{value: :await_user_input, resume: resume1}, _env} = Comp.run(comp)

      # Step 2: Provide user input, get response
      {result2, _env} = resume1.("Hi there")

      assert %Suspend{
               value: %{type: :response, text: text, tool_executions: tool_executions},
               resume: resume2
             } = result2

      assert text == "Hello back!"
      assert tool_executions == []

      # Step 3: Acknowledge response, get back to :await_user_input
      {result3, _env} = resume2.(:ok)

      assert %Suspend{value: :await_user_input} = result3
    end

    test "tool execution flow yields execute_tools" do
      state = ConversationComp.initial_state()

      # First response requests tool, second is final response
      handler =
        TestHandler.sequence([
          TestHandler.tool_use_response([
            %{id: "tool_1", name: "list_todos", input: %{}}
          ]),
          TestHandler.text_response("Here are your todos!")
        ])

      comp = build_comp(state, handler)

      # Step 1: Get :await_user_input
      {%Suspend{value: :await_user_input, resume: resume1}, _env} = Comp.run(comp)

      # Step 2: Provide user input, get execute_tools request
      {result2, _env} = resume1.("Show my todos")

      assert %Suspend{value: %{type: :execute_tools, tool_uses: tool_uses}, resume: resume2} =
               result2

      assert length(tool_uses) == 1
      assert hd(tool_uses).name == "list_todos"

      # Step 3: Provide tool results, get response
      tool_results = [{:ok, [%{id: "1", title: "Test todo"}]}]
      {result3, _env} = resume2.(tool_results)

      assert %Suspend{
               value: %{type: :response, text: text, tool_executions: tool_executions},
               resume: resume3
             } = result3

      assert text == "Here are your todos!"
      assert length(tool_executions) == 1

      # Step 4: Acknowledge, back to await_user_input
      {result4, _env} = resume3.(:ok)
      assert %Suspend{value: :await_user_input} = result4
    end

    test "multi-tool execution in single response" do
      state = ConversationComp.initial_state()

      handler =
        TestHandler.sequence([
          TestHandler.tool_use_response([
            %{id: "tool_1", name: "create_todo", input: %{"title" => "First"}},
            %{id: "tool_2", name: "create_todo", input: %{"title" => "Second"}}
          ]),
          TestHandler.text_response("Created both todos!")
        ])

      comp = build_comp(state, handler)

      {%Suspend{resume: resume1}, _env} = Comp.run(comp)
      {result2, _env} = resume1.("Create two todos")

      assert %Suspend{value: %{type: :execute_tools, tool_uses: tool_uses}} = result2
      assert length(tool_uses) == 2
    end

    test "handles LLM error gracefully" do
      state = ConversationComp.initial_state()

      comp =
        build_comp(state, TestHandler.error_response(:api_error))
        |> Throw.with_handler()

      {%Suspend{resume: resume1}, _env} = Comp.run(comp)
      {result2, _env} = resume1.("Hello")

      # Should yield an error
      assert %Suspend{value: %{type: :error, reason: :api_error}, resume: resume2} = result2

      # Should return to await_user_input after acknowledging error
      {result3, _env} = resume2.(:ok)
      assert %Suspend{value: :await_user_input} = result3
    end
  end

  describe "initial_state/1" do
    test "creates state with defaults" do
      state = ConversationComp.initial_state()

      assert state.messages == []
      assert state.tools == []
      assert is_binary(state.system)
    end

    test "accepts custom options" do
      tools = [%{name: "test_tool"}]
      state = ConversationComp.initial_state(tools: tools, system: "Custom system")

      assert state.tools == tools
      assert state.system == "Custom system"
    end

    test "accepts initial messages" do
      messages = [%{role: "user", content: "Hi"}]
      state = ConversationComp.initial_state(messages: messages)

      assert state.messages == messages
    end
  end

  describe "multi-turn conversation" do
    test "maintains message history across turns" do
      state = ConversationComp.initial_state()

      # Use recording handler to verify messages
      call_count = :counters.new(1, [:atomics])
      last_messages = :ets.new(:last_messages, [:set, :public])

      handler = fn %LlmCall.SendMessages{messages: msgs} ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)
        :ets.insert(last_messages, {:messages, msgs})

        %{
          text: "Response #{count}",
          tool_uses: [],
          needs_tools: false,
          raw: %{}
        }
      end

      comp = build_comp(state, handler)

      # Turn 1
      {%Suspend{resume: r1}, _} = Comp.run(comp)

      {%Suspend{value: %{type: :response, text: "Response 1"}, resume: r2}, _} =
        r1.("First message")

      # Check messages sent to LLM
      [{:messages, turn1_msgs}] = :ets.lookup(last_messages, :messages)
      assert length(turn1_msgs) == 1
      assert hd(turn1_msgs).content == "First message"

      # Turn 2
      {%Suspend{resume: r3}, _} = r2.(:ok)

      {%Suspend{value: %{type: :response, text: "Response 2"}, resume: _r4}, _} =
        r3.("Second message")

      # Check messages include history
      [{:messages, turn2_msgs}] = :ets.lookup(last_messages, :messages)
      # user1, assistant1, user2
      assert length(turn2_msgs) == 3
    end
  end

  describe "max tool iterations" do
    test "stops after max iterations" do
      state = ConversationComp.initial_state()

      # Handler that always requests tools (would loop forever)
      handler = fn %LlmCall.SendMessages{} ->
        %{
          text: "",
          tool_uses: [%{id: "tool_1", name: "list_todos", input: %{}}],
          needs_tools: true,
          raw: %{}
        }
      end

      comp = build_comp(state, handler)

      {%Suspend{resume: resume1}, _} = Comp.run(comp)
      result = iterate_until_limit(resume1.("Test"), 0)

      # Should eventually get an error about max iterations
      assert {:error, :max_tool_iterations} = result
    end
  end

  # Helper to iterate through tool execution until we hit the limit or get a response
  defp iterate_until_limit({%Suspend{value: %{type: :execute_tools}, resume: resume}, _}, count)
       when count < 15 do
    # Provide dummy tool results and continue
    iterate_until_limit(resume.([{:ok, "result"}]), count + 1)
  end

  defp iterate_until_limit({%Suspend{value: %{type: :response}}, _}, _count) do
    {:response, :got_response}
  end

  defp iterate_until_limit({%Suspend{value: %{type: :error, reason: reason}}, _}, _count) do
    {:error, reason}
  end

  defp iterate_until_limit(_, count) do
    {:error, {:unexpected_after, count}}
  end
end
