defmodule ExGoogleSTT.TranscriptionServer do
  @moduledoc """
  A Server to handle transcription requests.
  """
  use GenServer

  alias ExGoogleSTT.Grpc.SpeechClient, as: GrpcSpeechClient
  alias ExGoogleSTT.{Error, SpeechEvent, Transcript}

  alias Google.Cloud.Speech.V2.{
    RecognitionConfig,
    StreamingRecognitionConfig,
    StreamingRecognizeRequest,
    StreamingRecognizeResponse,
    StreamingRecognitionResult
  }

  # ================== APIs ==================
  @doc """
  Starts a transcription server.
  The basic usage is to start the server with the config you want. It is then kept in state and can be used to send audio requests later on.

  ## Examples

      iex> TranscriptionServer.start_link()
      {:ok, #PID<0.123.0>}

  ## Options
    These options are all optional. The recognizer should be the main point of configuration.


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
    with {:ok, _speech_client} <- get_or_start_speech_client(transcription_server_pid) do
      send_audio_data(transcription_server_pid, audio_data)
    end
  end

  @spec get_or_start_speech_client(pid()) :: {:ok, pid()}
  defp get_or_start_speech_client(transcription_server_pid) do
    speech_client =
      GenServer.call(transcription_server_pid, {:get_or_start_speech_client}, :infinity)

    {:ok, speech_client}
  end

  def end_stream(transcription_server_pid),
    do: GenServer.call(transcription_server_pid, :end_stream)

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
          :ok = send_config(speech_client, state.config_request)
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
    case speech_client_state(state) do
      :open ->
        :ok = GrpcSpeechClient.end_stream(state.speech_client)
        {:reply, :ok, %{state | stream_state: :closed, speech_client: nil}}

      :closed ->
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  # This ensures the transcriptions server is killed if the caller dies
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{target: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(recognize_response, %{target: target} = state) do
    entries = parse_response(recognize_response)

    for entry <- entries do
      send(target, entry)
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
    # This assumes the recognizer has the proper configurations, so we'll only override the ones that are passed in
    recognition_config =
      %RecognitionConfig{}
      |> cast_decoding_config()
      |> cast_model()
      |> cast_language_codes()
      |> cast_automatic_punctuation()

    # ABSOLUTELY NECESSARY FOR INFINITE STREAMING, because it lets us receive a response immediately after the stream is opened
    activity_events = true

    interim_results = Map.get(opts_map, :interim_results, false)

    %StreamingRecognitionConfig{
      streaming_features: %{
        enable_voice_activity_events: activity_events,
        interim_results: interim_results
      }
    }
    |> cast_recognition_config(recognition_config)
  end

  # do not send the config if empty
  defp cast_recognition_config(stream_rec_config, recognition_config)
       when recognition_config == %RecognitionConfig{},
       do: stream_rec_config

  defp cast_recognition_config(stream_rec_config, recognition_config) do
    stream_rec_config
    |> Map.put(:config, recognition_config)
  end

  defp cast_decoding_config(%{decoding_config: decoding_config} = recognition_config) do
    recognition_config
    |> Map.put(:decoding_config, decoding_config)
  end

  defp cast_decoding_config(recognition_config), do: recognition_config

  defp cast_model(%{model: model} = recognition_config) do
    recognition_config
    |> Map.put(:model, model)
  end

  defp cast_model(recognition_config), do: recognition_config

  defp cast_language_codes(%{language_codes: language_codes} = recognition_config) do
    recognition_config
    |> Map.put(:language_codes, language_codes)
  end

  defp cast_language_codes(recognition_config), do: recognition_config

  defp cast_automatic_punctuation(
         %{enable_automatic_punctuation: enable_automatic_punctuation} = recognition_config
       ) do
    recognition_config
    |> Map.put(:features, %{enable_automatic_punctuation: enable_automatic_punctuation})
  end

  defp cast_automatic_punctuation(recognition_config), do: recognition_config

  defp default_recognizer, do: Application.get_env(:ex_google_stt, :recognizer)

  defp build_audio_request(audio_data, recognizer) do
    %StreamingRecognizeRequest{streaming_request: {:audio, audio_data}, recognizer: recognizer}
  end

  defp speech_client_state(%{speech_client: nil}), do: :closed

  defp speech_client_state(state) do
    case Process.alive?(state.speech_client) do
      true -> :open
      false -> :closed
    end
  end

  @spec send_config(pid(), StreamingRecognizeRequest.t()) :: :ok
  defp send_config(speech_client, cfg_request), do: send_request(speech_client, cfg_request)

  @spec send_request(pid(), StreamingRecognizeRequest.t()) :: :ok
  defp send_request(speech_client, request) do
    GrpcSpeechClient.send_request(speech_client, request)
  end

  defp send_audio_data(transcription_server_pid, audio_data) do
    GenServer.call(transcription_server_pid, {:send_audio_request, audio_data}, :infinity)
  end

  defp parse_response(%StreamingRecognizeResponse{results: results}) when results != [] do
    parse_results(results)
  end

  defp parse_response(%StreamingRecognizeResponse{speech_event_type: event_type}),
    do: [{:stt_event, %SpeechEvent{event: event_type}}]

  # This is a normal timeout, no alarm needed
  defp parse_response({:error, %GRPC.RPCError{status: 10}}),
    do: [{:stt_event, :stream_timeout}]

  defp parse_response({:error, %GRPC.RPCError{status: status, message: message}}),
    do: [{:stt_event, %Error{status: status, message: message}}]

  # Ignoring the noise for now
  defp parse_response(_), do: []

  defp parse_results(results) do
    results_content = Enum.map_join(results, "", &parse_result(&1))
    is_final = Enum.any?(results, & &1.is_final)

    [{:stt_event, %Transcript{content: results_content, is_final: is_final}}]
  end

  defp parse_result(%StreamingRecognitionResult{alternatives: [alternative]}),
    do: alternative.transcript
end
