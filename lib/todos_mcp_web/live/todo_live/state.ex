defmodule TodosMcpWeb.TodoLive.State do
  @moduledoc """
  Typed state structs for TodoLive.

  Groups related assigns into typed structs for better LSP support,
  compile-time field checking, and documentation.

  ## Structure

  - `TodosState` - Todo list, stats, filter, form input
  - `ApiKeysState` - API key configuration and provider selection
  - `ChatState` - Conversation state, messages, voice recording
  - `LogModalState` - Effect log modal state
  """

  alias TodosMcp.Todos.Todo
  alias TodosMcp.Llm.ConversationRunner

  defmodule TodosState do
    @moduledoc "Todo list state"
    defstruct items: [],
              stats: %{total: 0, active: 0, completed: 0},
              filter: :all,
              new_title: ""

    @type filter :: :all | :active | :completed
    @type stats :: %{
            total: non_neg_integer(),
            active: non_neg_integer(),
            completed: non_neg_integer()
          }

    @type t :: %__MODULE__{
            items: [Todo.t()],
            stats: stats(),
            filter: filter(),
            new_title: String.t()
          }
  end

  defmodule ApiKeysState do
    @moduledoc "API key configuration state"
    defstruct anthropic: nil,
              gemini: nil,
              groq: nil,
              source: nil,
              selected_provider: :claude

    @type provider :: :claude | :gemini | :groq
    @type source :: :session | :env | nil

    @type t :: %__MODULE__{
            anthropic: String.t() | nil,
            gemini: String.t() | nil,
            groq: String.t() | nil,
            source: source(),
            selected_provider: provider()
          }

    @doc "Get the API key for the currently selected provider"
    @spec current_key(t()) :: String.t() | nil
    def current_key(%__MODULE__{} = keys) do
      case keys.selected_provider do
        :claude -> keys.anthropic
        :gemini -> keys.gemini
        :groq -> keys.groq
      end
    end

    @doc "Get the API key for a specific provider"
    @spec key_for(t(), provider()) :: String.t() | nil
    def key_for(%__MODULE__{} = keys, :claude), do: keys.anthropic
    def key_for(%__MODULE__{} = keys, :gemini), do: keys.gemini
    def key_for(%__MODULE__{} = keys, :groq), do: keys.groq
  end

  defmodule ChatState do
    @moduledoc "Chat/conversation state"
    defstruct messages: [],
              input: "",
              loading: false,
              error: nil,
              runner: nil,
              is_recording: false,
              is_transcribing: false

    @type message :: %{
            role: :user | :assistant,
            content: String.t(),
            tool_executions: list() | nil
          }

    @type t :: %__MODULE__{
            messages: [message()],
            input: String.t(),
            loading: boolean(),
            error: String.t() | nil,
            runner: ConversationRunner.t() | nil,
            is_recording: boolean(),
            is_transcribing: boolean()
          }

    @doc "Add a message to the conversation"
    @spec add_message(t(), message()) :: t()
    def add_message(%__MODULE__{} = chat, message) do
      %{chat | messages: chat.messages ++ [message]}
    end

    @doc "Clear the conversation"
    @spec clear(t()) :: t()
    def clear(%__MODULE__{} = chat) do
      %{chat | messages: [], error: nil}
    end
  end

  defmodule LogModalState do
    @moduledoc "Effect log modal state"
    defstruct tab: :inspect,
              inspect: nil,
              json: nil

    @type tab :: :inspect | :json

    @type t :: %__MODULE__{
            tab: tab(),
            inspect: String.t() | nil,
            json: String.t() | nil
          }
  end
end
