# TodosMcp

A **voice-controllable** todo application demonstrating how **command/query structs**
combined with **algebraic effects** enable trivial LLM integration and property-based
testing.

**Live demo**: https://todos-mcp-lu6h.onrender.com/

## What is TodosMcp?

TodosMcp is a Phoenix LiveView todo application with an embedded LLM assistant.
Users can manage todos through the traditional UI, by chatting with an AI, or
by **speaking to it**—the app transcribes audio and the assistant executes
commands hands-free.

The interesting part isn't the todo features—it's the architecture that makes
LLM integration almost free once you've structured your domain logic correctly.

## Command/Query Structs

Every action in the application is represented as a struct:

```elixir
# Commands (mutations)
%CreateTodo{title: "Buy milk", priority: :high}
%ToggleTodo{id: "abc-123"}
%CompleteAll{}

# Queries (reads)
%ListTodos{filter: :active, sort_by: :priority}
%GetStats{}
```

These structs are:
- **Serializable** - JSON round-trips via `from_json/1`
- **Self-documenting** - `@moduledoc` describes what they do
- **Typed** - `@type` specs define their schema

A single `DomainHandler` dispatches on struct type:

```elixir
defcomp handle(%CreateTodo{} = cmd) do
  ctx <- Reader.ask(CommandContext)
  id <- Fresh.fresh_uuid()
  changeset = Todo.changeset(%Todo{}, %{id: id, tenant_id: ctx.tenant_id, ...})
  todo <- EctoPersist.insert(changeset)
  {:ok, todo}
end

defcomp handle(%ListTodos{filter: filter, sort_by: sort_by, sort_order: sort_order}) do
  ctx <- Reader.ask(CommandContext)
  todos <- DataAccess.list_todos(ctx.tenant_id, %{filter: filter, ...})
  {:ok, todos}
end
```

## Trivial LLM Integration

Because every action is a struct with metadata, generating LLM tools is automatic:

```elixir
# lib/todos_mcp/mcp/tools.ex
def all do
  (Commands.all() ++ Queries.all()) |> Enum.map(&to_tool/1)
end

def to_tool(module) do
  %{
    name: tool_name(module),           # CreateTodo -> "create_todo"
    description: tool_description(module),  # from @moduledoc
    inputSchema: input_schema(module)  # from struct fields + @type
  }
end
```

The LLM calls tools by name, we deserialize to a struct, execute through the
same `DomainHandler`, and return the result. **Zero special-casing for AI**—the
LLM uses exactly the same code paths as the UI.

## Skuld Effects

TodosMcp uses [Skuld](https://github.com/mccraigmccraig/skuld), an algebraic
effects library for Elixir. Effects let you write domain logic that *describes*
what it needs without *performing* the operations directly.

### Three-Layer Architecture

**1. Pure Layer** - Command/Query structs and their validation. No effects,
trivially testable.

**2. Effectful Layer** - `DomainHandler` uses effects to describe operations:

```elixir
defcomp handle(%ToggleTodo{id: id}) do
  ctx <- Reader.ask(CommandContext)        # "I need the command context"
  todo <- DataAccess.get_todo!(ctx.tenant_id, id)  # "I need this todo"
  changeset = Todo.changeset(todo, %{completed: not todo.completed})
  updated <- EctoPersist.update(changeset)  # "Persist this change"
  {:ok, updated}
end
```

This code doesn't *do* database queries or persistence—it *requests* them.
The actual implementation is provided by handlers at runtime.

**3. Side-Effecting Layer** - Handlers that perform real I/O. This is boring
plumbing code:

```elixir
# Run.execute/2 composes the handler stack
comp
|> Command.with_handler(&DomainHandler.handle/1)
|> Reader.with_handler(context, tag: CommandContext)
|> Query.with_handler(%{DataAccess.Impl => :direct})  # or InMemoryImpl
|> EctoPersist.with_handler(Repo)
|> Fresh.with_uuid7_handler()
|> Throw.with_handler()
|> Comp.run()
```

### Why This Matters for LLM Integration

The LLM conversation loop is itself an effectful computation:

```elixir
defcomp run(state) do
  user_message <- Yield.yield(:await_user_input)     # Suspend for input
  messages = state.messages ++ [%{role: "user", content: user_message}]

  result <- conversation_turn(messages, state.tools, [], 0)

  case result do
    {:ok, text, final_messages, tool_executions} ->
      _yielded <- Yield.yield({:response, text, tool_executions})
      run(%{state | messages: final_messages})  # Loop
  end
end
```

The `Yield` effect lets the conversation **suspend** waiting for user input
or tool execution, then **resume** when results are available. This is a
natural fit for Phoenix LiveView's message-based architecture—no callbacks,
no state machines, just a straightforward loop that suspends and resumes.

### Voice Control

Voice input uses another effect—`Transcribe`—to convert audio to text:

```elixir
defcomp transcribe_and_chat(audio_data) do
  text <- Transcribe.transcribe(audio_data)  # Groq Whisper API
  # Feed transcribed text into the conversation...
end
```

The effect abstraction means we can swap Groq for OpenAI Whisper, local
transcription, or a test stub—without changing the conversation logic.

## Property-Based Testing

The biggest win from algebraic effects: **testability**.

Since `DomainHandler` only *describes* operations via effects, we can run it
with pure in-memory handlers instead of a real database:

```elixir
defp run_with_todos(operation, todos) do
  InMemoryStore.clear()
  for todo <- todos, do: InMemoryStore.insert(todo)
  Run.execute(operation, mode: :in_memory, tenant_id: @test_tenant)
end
```

This enables property-based testing with thousands of iterations per second:

```elixir
property "ToggleTodo is self-inverse" do
  check all(todo <- Generators.todo(tenant_id: @test_tenant)) do
    {:ok, toggled} = run_with_todos(%ToggleTodo{id: todo.id}, [todo])
    {:ok, restored} = run_with_todos(%ToggleTodo{id: todo.id}, [toggled])
    assert restored.completed == todo.completed
  end
end

property "CompleteAll only affects incomplete todos" do
  check all(todos <- Generators.todos(min_length: 1, max_length: 20)) do
    incomplete_count = Enum.count(todos, &(not &1.completed))
    {:ok, %{updated: count}} = run_with_todos(%CompleteAll{}, todos)
    assert count == incomplete_count
  end
end
```

The **exact same domain logic** runs in production with Postgres and in tests
with pure in-memory storage. No mocking, no test doubles—just different effect
handlers.

## Getting Started

```bash
# Install dependencies
mix setup

# Start the server
mix phx.server
```

Visit http://localhost:4000 and try chatting with the assistant!

## Configuration

```elixir
# config/config.exs

# Storage mode (:database or :in_memory)
config :todos_mcp, :storage_mode, :in_memory

# Claude API key for the chat assistant
config :todos_mcp, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
```

## Project Structure

```
lib/todos_mcp/
├── commands.ex          # Command structs (CreateTodo, ToggleTodo, etc.)
├── queries.ex           # Query structs (ListTodos, GetStats, etc.)
├── domain_handler.ex    # Effectful domain logic
├── run.ex               # Handler composition
├── data_access.ex       # Query effect for data access
├── data_access/
│   └── in_memory_impl.ex  # Pure in-memory implementation
├── effects/
│   ├── llm_call.ex      # Effect for LLM API calls
│   └── transcribe.ex    # Effect for audio transcription
├── llm/
│   ├── conversation_comp.ex   # Conversation loop as effectful computation
│   └── conversation_runner.ex # LiveView integration
└── mcp/
    └── tools.ex         # Auto-generate tools from command/query structs
```

## License

MIT
