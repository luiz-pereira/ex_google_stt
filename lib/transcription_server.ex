defmodule ExGoogleSTT.TranscriptionServer do
  @moduledoc """
  A Server to handle transcription requests.
  """
  use GenServer

  alias ExGoogleSTT.GrpcSpeechClient
  alias ExGoogleSTT.Transcript

  alias Google.Cloud.Speech.V2.{
    AutoDetectDecodingConfig,
    RecognitionConfig,
    StreamingRecognitionConfig,
    StreamingRecognizeRequest,
    StreamingRecognizeResponse,
    StreamingRecognitionResult
  }

  alias GRPC.Stub, as: GrpcStub
  alias GRPC.Client.Stream, as: GrpcStream

  @default_model "latest_long"
  @default_language_codes ["en-US"]

  # ================== APIs ==================
  @doc """
  Starts a transcription server.
  The basic usage is to start the server with the config you want. It is then kept in state and can be used to send audio requests later on.

  ## Examples

      iex> TranscriptionServer.start_link()
      {:ok, #PID<0.123.0>}

  ## Options
    - target - a pid to send the results to, defaults to self()
    - language_codes - a list of language codes to use for recognition, defaults to ["en-US"]
    - enable_automatic_punctuation - a boolean to enable automatic punctuation, defaults to true
    - interim_results - a boolean to enable interim results, defaults to false
    - recognizer - a string representing the recognizer to use, defaults to use the recognizer from the config
    - model - a string representing the model to use, defaults to "latest_long". Be careful, changing to 'short' may have unintended consequences
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc """
  That's the main entrypoint for processing audio.
  It will start a stream, if it's not already started and send the audio to it.
  It will also send the config if it's not already sent.
  """
  @spec process_audio(pid(), binary()) :: :ok
  def process_audio(transcription_server_pid, audio_data) do
    with speech_client_pid <- get_or_start_speech_client(transcription_server_pid) do
      send_audio_data(transcription_server_pid, speech_client_pid, audio_data)
    end
  end

  # @doc """
  # Gets the speech_client that controls the responses
  # """
  @spec get_or_start_speech_client(pid()) :: GrpcStream.t()
  def get_or_start_speech_client(transcription_server_pid) do
    GenServer.call(transcription_server_pid, {:get_or_start_speech_client})
  end

  # ================== GenServer ==================

  @impl GenServer
  def init(opts_map) do
    target = Map.get(opts_map, :target, self())
    config_request = build_config_request(opts_map)
    recognizer = Map.get(opts_map, :recognizer, default_recognizer())

    # This ensures the transcriptions server is killed if the caller dies
    Process.monitor(target)

    {:ok,
     %{
       target: target,
       recognizer: recognizer,
       config_request: config_request,
       speech_client: nil,
       stream_state: :closed
     }}
  end

  @impl GenServer
  def handle_call({:get_or_start_speech_client}, _from, state) do
    speech_client =
      case speech_client_state(state) do
        :closed ->
          {:ok, speech_client} = GrpcSpeechClient.start_link()
          {:ok, _} = send_config(speech_client, state.config_request)
          speech_client

        :open ->
          state.speech_client
      end

    {:reply, speech_client, %{state | speech_client: speech_client, stream_state: :open}}
  end

  @impl GenServer
  def handle_call({:send_audio_request, audio_data}, _from, state) do
    audio_request = build_audio_request(audio_data, state.recognizer)
    send_request(state.speech_client, audio_request)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:end_stream, _from, state) do
    # TODO check if the client will die on its own
    GrpcSpeechClient.end_stream(state.speech_client)
    {:reply, :ok, %{state | stream_state: :closed, speech_client: nil}}
  end

  @impl GenServer
  # This ensures the transcriptions server is killed if the caller dies
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{target: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(recognize_response, %{target: target} = state) do
    entries = parse_response(recognize_response)

    for entry <- entries do
      send(target, {:response, entry})
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ================== GenServer Helpers ==================
  defp build_config_request(opts_map) do
    stream_recognition_cfg = build_str_recognition_config(opts_map)
    recognizer = Map.get(opts_map, :recognizer, default_recognizer())

    %StreamingRecognizeRequest{
      streaming_request: {:streaming_config, stream_recognition_cfg},
      recognizer: recognizer
    }
  end

  defp build_str_recognition_config(opts_map) do
    recognition_config = %RecognitionConfig{
      decoding_config: {:auto_decoding_config, %AutoDetectDecodingConfig{}},
      model: Map.get(opts_map, :model, @default_model),
      language_codes: Map.get(opts_map, :language_codes, @default_language_codes),
      features: %{
        enable_automatic_punctuation: Map.get(opts_map, :enable_automatic_punctuation, true)
      }
    }

    # ABSOLUTELY NECESSARY FOR INFINITE STREAMING, because it lets us receive a response immediately after the stream is opened
    activity_events = true

    interim_results = Map.get(opts_map, :interim_results, false)

    %StreamingRecognitionConfig{
      config: recognition_config,
      streaming_features: %{
        enable_voice_activity_events: activity_events,
        interim_results: interim_results
      }
    }
  end

  defp default_recognizer, do: Application.get_env(:ex_google_stt, :recognizer)

  defp build_audio_request(audio_data, recognizer) do
    %StreamingRecognizeRequest{streaming_request: {:audio, audio_data}, recognizer: recognizer}
  end

  defp speech_client_state(%{speech_client: nil}), do: :closed

  defp speech_client_state(%{stream_state: :closed}) do
    # maybe kill the client if it is not dead yet?
    :closed
  end

  defp speech_client_state(_), do: :open

  defp end_stream(stream), do: GenServer.call(stream, :end_stream)

  @spec send_config(GrpcStream.t(), StreamingRecognizeRequest.t()) :: :ok
  defp send_config(speech_client, cfg_request), do: send_request(speech_client, cfg_request)

  @spec send_request(GrpcStream.t(), StreamingRecognizeRequest.t()) :: :ok
  defp send_request(speech_client, request) do
    GrpcSpeechClient.send_request(speech_client, request)
  end

  defp send_audio_data(transcription_server_pid, audio_data) do
    GenServer.call(transcription_server_pid, {:send_audio_request, audio_data})
  end

  defp parse_response({:ok, %StreamingRecognizeResponse{results: results}}) when results != [] do
    parse_results(results)
  end

  defp parse_response({:ok, %StreamingRecognizeResponse{} = response}), do: [response]

  defp parse_response({:error, error}), do: [error]

  # Ignoring the noise for now
  defp parse_response(_), do: []

  defp parse_results(results) do
    for result <- results do
      parse_result(result)
    end
  end

  defp parse_result(%StreamingRecognitionResult{alternatives: [alternative]} = result) do
    %Transcript{content: alternative.transcript, is_final: result.is_final}
  end
end
