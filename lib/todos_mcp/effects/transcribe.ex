defmodule TodosMcp.Effects.Transcribe do
  @moduledoc """
  Transcribe effect - Speech-to-text transcription.

  This effect handles sending audio data to a transcription service
  and receiving text back.

  ## Response Format

  Handlers should return:

      {:ok, %{text: String.t(), language: String.t() | nil, duration: float() | nil}}

  Or:

      {:error, reason}

  ## Usage

      use Skuld.Syntax
      alias TodosMcp.Effects.Transcribe

      defcomp transcribe_audio(audio_data) do
        result <- Transcribe.transcribe(audio_data, format: :webm)
        result.text
      end
      |> Transcribe.with_handler(GroqHandler.handler(api_key: key))
      |> Comp.run()

  ## Handlers

  - `GroqHandler` - Groq Whisper API (fast, free tier)
  - `TestHandler` - Stubbed responses for testing
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Type Definitions
  #############################################################################

  @type transcription :: %{
          text: String.t(),
          language: String.t() | nil,
          duration: float() | nil
        }

  @type handler_fn :: (op :: term() -> {:ok, transcription()} | {:error, term()})

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(TranscribeAudio, [:audio_data, :opts])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Transcribe audio data to text.

  ## Arguments

  - `audio_data` - Binary audio data
  - `opts` - Keyword options:
    - `:format` - Audio format (`:webm`, `:mp3`, `:wav`, `:m4a`, etc.)
    - `:language` - Optional language hint (ISO 639-1 code)
    - `:prompt` - Optional prompt to guide transcription

  ## Returns

  A computation that, when run with a handler, returns a transcription map.

  ## Example

      defcomp handle_voice(audio) do
        result <- Transcribe.transcribe(audio, format: :webm)
        result.text
      end
  """
  @spec transcribe(binary(), keyword()) :: Types.computation()
  def transcribe(audio_data, opts \\ []) do
    Comp.effect(@sig, %TranscribeAudio{audio_data: audio_data, opts: opts})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a Transcribe handler for a computation.

  The handler function receives the operation struct and should return
  `{:ok, transcription}` or `{:error, reason}`.

  ## Example

      my_computation
      |> Transcribe.with_handler(fn %TranscribeAudio{audio_data: data, opts: opts} ->
        # Call transcription API
        {:ok, %{text: "Hello world", language: "en", duration: 1.5}}
      end)
      |> Comp.run()
  """
  @spec with_handler(Types.computation(), handler_fn()) :: Types.computation()
  def with_handler(comp, handler_fn) do
    Comp.with_handler(comp, @sig, fn op, env, k ->
      case handler_fn.(op) do
        {:ok, _} = result ->
          k.(result, env)

        {:error, _} = error ->
          k.(error, env)
      end
    end)
  end

  #############################################################################
  ## Signature Access (for testing/introspection)
  #############################################################################

  @doc false
  def signature, do: @sig
end
