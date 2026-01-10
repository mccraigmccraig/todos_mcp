defmodule TodosMcp.Effects.Transcribe.TestHandler do
  @moduledoc """
  Test handler for the Transcribe effect.

  Provides stubbed transcription responses for testing without hitting
  external APIs.

  ## Usage

      alias TodosMcp.Effects.Transcribe
      alias TodosMcp.Effects.Transcribe.TestHandler

      # Static response
      my_computation
      |> Transcribe.with_handler(TestHandler.handler(text: "Hello world"))
      |> Comp.run()

      # Dynamic response based on audio data
      my_computation
      |> Transcribe.with_handler(TestHandler.handler(fn _audio, _opts ->
        {:ok, %{text: "Dynamic response", language: "en", duration: 1.5}}
      end))
      |> Comp.run()
  """

  alias TodosMcp.Effects.Transcribe

  @doc """
  Create a test handler that returns stubbed responses.

  ## Options

  - `:text` - Static text to return. Default: "Test transcription"
  - `:language` - Language to return. Default: "en"
  - `:duration` - Duration to return. Default: 1.0
  - `:error` - If set, returns this error instead

  Or pass a function `(audio_data, opts) -> {:ok, transcription} | {:error, reason}`
  """
  @spec handler(keyword() | function()) :: Transcribe.handler_fn()
  def handler(opts_or_fn \\ [])

  def handler(func) when is_function(func, 2) do
    fn %Transcribe.TranscribeAudio{audio_data: audio_data, opts: opts} ->
      func.(audio_data, opts)
    end
  end

  def handler(opts) when is_list(opts) do
    fn %Transcribe.TranscribeAudio{} ->
      case Keyword.get(opts, :error) do
        nil ->
          {:ok,
           %{
             text: Keyword.get(opts, :text, "Test transcription"),
             language: Keyword.get(opts, :language, "en"),
             duration: Keyword.get(opts, :duration, 1.0)
           }}

        error ->
          {:error, error}
      end
    end
  end
end
