defmodule TodosMcp.Effects.Transcribe.GroqHandler do
  @moduledoc """
  Groq Whisper handler for the Transcribe effect.

  Uses Groq's OpenAI-compatible Whisper API for fast speech-to-text
  transcription.

  ## Usage

      alias TodosMcp.Effects.Transcribe
      alias TodosMcp.Effects.Transcribe.GroqHandler

      my_computation
      |> Transcribe.with_handler(GroqHandler.handler(api_key: "gsk_..."))
      |> Comp.run()

  ## Configuration

  - `:api_key` - Required. Groq API key.
  - `:model` - Model to use. Default: "whisper-large-v3-turbo"
  - `:language` - Optional language hint (ISO 639-1).
  - `:prompt` - Optional prompt to guide transcription.

  ## Free Tier Limits

  Groq offers generous free tier limits for Whisper:
  - whisper-large-v3-turbo: 7,200 requests/day
  - ~28,800 audio seconds/day
  """

  alias TodosMcp.Effects.Transcribe

  @api_url "https://api.groq.com/openai/v1/audio/transcriptions"
  @default_model "whisper-large-v3-turbo"

  # Map audio formats to MIME types and file extensions
  @format_info %{
    webm: {"audio/webm", "audio.webm"},
    mp3: {"audio/mpeg", "audio.mp3"},
    wav: {"audio/wav", "audio.wav"},
    m4a: {"audio/m4a", "audio.m4a"},
    ogg: {"audio/ogg", "audio.ogg"},
    flac: {"audio/flac", "audio.flac"}
  }

  @doc """
  Create a handler function for the Transcribe effect using Groq Whisper.

  ## Options

  - `:api_key` - Required. Groq API key.
  - `:model` - Model to use. Options: "whisper-large-v3", "whisper-large-v3-turbo"
  - `:language` - Language hint (ISO 639-1 code like "en", "es", etc.)
  - `:prompt` - Prompt to guide transcription style/vocabulary.

  ## Returns

  A handler function suitable for `Transcribe.with_handler/2`.
  """
  @spec handler(keyword()) :: Transcribe.handler_fn()
  def handler(base_config \\ []) do
    fn %Transcribe.TranscribeAudio{audio_data: audio_data, opts: call_opts} ->
      merged_opts = Keyword.merge(base_config, call_opts)
      transcribe(audio_data, merged_opts)
    end
  end

  @doc """
  Transcribe audio using Groq's Whisper API.

  ## Options

  - `:api_key` - Required. Groq API key.
  - `:format` - Audio format (`:webm`, `:mp3`, etc.). Default: `:webm`
  - `:model` - Whisper model. Default: "whisper-large-v3-turbo"
  - `:language` - Optional language hint.
  - `:prompt` - Optional transcription prompt.

  ## Returns

  - `{:ok, %{text: String.t(), language: String.t() | nil, duration: float() | nil}}`
  - `{:error, reason}`
  """
  @spec transcribe(binary(), keyword()) ::
          {:ok, Transcribe.transcription()} | {:error, term()}
  def transcribe(audio_data, opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    format = Keyword.get(opts, :format, :webm)
    model = Keyword.get(opts, :model, @default_model)

    {content_type, filename} = Map.get(@format_info, format, {"audio/webm", "audio.webm"})

    # Build multipart form using Req's form_multipart format
    form_parts = [
      file: {audio_data, filename: filename, content_type: content_type},
      model: model,
      response_format: "verbose_json"
    ]

    # Add optional parameters
    form_parts =
      form_parts
      |> maybe_add_part(:language, Keyword.get(opts, :language))
      |> maybe_add_part(:prompt, Keyword.get(opts, :prompt))

    case Req.post(@api_url,
           form_multipart: form_parts,
           headers: [{"authorization", "Bearer #{api_key}"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, normalize_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp maybe_add_part(parts, _key, nil), do: parts
  defp maybe_add_part(parts, key, value), do: parts ++ [{key, to_string(value)}]

  defp normalize_response(body) do
    %{
      text: body["text"] || "",
      language: body["language"],
      duration: body["duration"]
    }
  end
end
