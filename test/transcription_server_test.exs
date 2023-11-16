defmodule ExGoogleSTT.TranscriptionServerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias ExGoogleSTT.{Fixtures, Transcript, TranscriptionServer}

  alias GRPC.Client.Stream

  alias Google.Cloud.Speech.V2.{
    StreamingRecognizeResponse,
    StreamingRecognitionResult,
    SpeechRecognitionAlternative
  }

  describe "send_config/3" do
    test "succesfully sends a config request to the Stream Client" do
      config_request = Fixtures.config_request()
      {:ok, stream} = TranscriptionServer.start_stream()
      assert {:ok, %Stream{}} = TranscriptionServer.send_config(stream, config_request)
    end

    test "fails if sending a bad config" do
      config_request = Fixtures.bad_config_request()
      {:ok, stream} = TranscriptionServer.start_stream()

      assert_raise Protobuf.EncodeError, fn ->
        TranscriptionServer.send_config(stream, config_request)
      end
    end
  end

  describe "send_request/3" do
    test "succesfully sends a request to the Stream Client" do
      audio_request = Fixtures.audio_request()
      {:ok, stream} = TranscriptionServer.start_stream()
      assert {:ok, %Stream{}} = TranscriptionServer.send_request(stream, audio_request)
    end

    test "fails if sending a bad request" do
      audio_request = Fixtures.bad_audio_request()
      {:ok, stream} = TranscriptionServer.start_stream()

      assert_raise Protobuf.EncodeError, fn ->
        TranscriptionServer.send_request(stream, audio_request)
      end
    end
  end

  describe "receive_stream_responses/2" do
    test "successfully performs the function sent on every response" do
      config_request = Fixtures.config_request()
      audio_request = Fixtures.audio_request()

      {:ok, stream} = TranscriptionServer.start_stream()

      TranscriptionServer.send_config(stream, config_request)
      TranscriptionServer.send_request(stream, audio_request)

      target = self()

      func = fn
        {:headers, _} ->
          nil

        response ->
          assert {:ok, %StreamingRecognizeResponse{} = recognize_response} = response
          send(target, {:response, recognize_response})
      end

      # ending the stream to receive the response. Usually not needed, but the audio does not end in silence
      TranscriptionServer.end_stream(stream)
      TranscriptionServer.receive_stream_responses(stream, func)

      assert_transcript("Advent", false)
    end
  end

  describe "Transcription Tests - " do
    setup do
      {:ok, stream} = TranscriptionServer.start_stream()
      config_request = Fixtures.config_request(interim_results: false)
      {:ok, stream} = TranscriptionServer.send_config(stream, config_request)

      target = self()

      func = fn
        {:headers, _} ->
          nil

        response ->
          assert {:ok, %StreamingRecognizeResponse{} = recognize_response} = response
          send(target, {:response, recognize_response})
      end

      {:ok, %{stream: stream, func: func}}
    end

    test "successfully transcribes data sent in chunks", %{stream: stream, func: func} do
      audio_chunks = Fixtures.chunked_audio_bytes()

      Enum.map(audio_chunks, fn data ->
        TranscriptionServer.send_request(stream, Fixtures.audio_request(data))
      end)

      TranscriptionServer.receive_stream_responses(stream, func)

      assert_transcript(
        "Adventure 1 a scandal in Bohemia from the Adventures of Sherlock Holmes by Sir Arthur Conan Doyle"
      )
    end

    test "successfully transcribes data sent in chunks, even if requests are sent after we start receiving response",
         %{func: func} do
      {:ok, stream} = TranscriptionServer.start_stream()
      config_request = Fixtures.config_request(interim_results: false)
      {:ok, stream} = TranscriptionServer.send_config(stream, config_request)

      audio_chunks = Fixtures.chunked_audio_bytes()
      {first_chunk, rest_of_chunks} = Enum.split(audio_chunks, 2)
      {second_chunk, rest_of_chunks} = Enum.split(rest_of_chunks, 2)

      # send first 2 requests
      Enum.each(first_chunk, fn data ->
        TranscriptionServer.send_request(stream, Fixtures.audio_request(data))
      end)

      # Now ask for the responses
      TranscriptionServer.receive_stream_responses(stream, func)

      # send the second chunk
      Enum.each(second_chunk, fn data ->
        TranscriptionServer.send_request(stream, Fixtures.audio_request(data))
      end)

      # send the rest of the chunks
      Enum.each(rest_of_chunks, fn data ->
        TranscriptionServer.send_request(stream, Fixtures.audio_request(data))
      end)

      assert_transcript(
        "Adventure 1 a scandal in Bohemia from the Adventures of Sherlock Holmes by Sir Arthur Conan Doyle"
      )
    end

    test "fails if Audio data is larger than 25_600 bytes", %{stream: stream} do
      target = self()

      func = fn
        {:headers, _} ->
          nil

        response ->
          assert {:error,
                  %GRPC.RPCError{
                    status: 3,
                    message: "Audio chunk can be of a a maximum of 25600 bytes" <> _
                  }} = response

          send(target, {:response, response})
      end

      audio_request = Fixtures.audio_request(Fixtures.full_audio_bytes())
      TranscriptionServer.send_request(stream, audio_request)
      TranscriptionServer.receive_stream_responses(stream, func)
      assert_receive {:response, _response}, 1000
    end

    test "produces interim results", %{func: func} do
      {:ok, stream} = TranscriptionServer.start_stream()
      config_request = Fixtures.config_request(interim_results: true)
      {:ok, stream} = TranscriptionServer.send_config(stream, config_request)

      audio_chunks = Fixtures.chunked_audio_bytes()

      Enum.map(audio_chunks, fn data ->
        TranscriptionServer.send_request(stream, Fixtures.audio_request(data))
      end)

      TranscriptionServer.receive_stream_responses(stream, func)

      %{last_response: last_response, interim_results: interim_results} =
        capture_interim_responses()

      %{transcript: final_transcript, is_final: true} = last_response

      assert_interim_results(interim_results)

      assert final_transcript ==
               "Adventure 1 a scandal in Bohemia from the Adventures of Sherlock Holmes by Sir Arthur Conan Doyle"
    end
  end

  defp capture_interim_responses(interim_results \\ []) do
    assert_receive {:response, %StreamingRecognizeResponse{} = response}, 150_000
    parsed_results = parse_results(response.results)
    interim_results = interim_results ++ parsed_results

    if last_response = Enum.find(parsed_results, & &1.is_final) do
      %{last_response: last_response, interim_results: interim_results}
    else
      capture_interim_responses(interim_results)
    end
  end

  defp parse_results(results) do
    for result <- results do
      %{alternatives: [%{transcript: transcript}], is_final: is_final} = result
      %{transcript: transcript, is_final: is_final}
    end
  end

  # This checks for 90% accuracy, as the interim results are not deterministic
  defp assert_interim_results(interim_results) when is_list(interim_results) do
    interim_transcripts =
      interim_results
      |> Enum.map(&(&1.transcript |> String.trim() |> String.downcase()))

    expected_interims =
      Fixtures.interim_results()
      |> Enum.map(&(String.trim(&1) |> String.downcase()))

    matches =
      interim_transcripts
      |> Enum.reduce(0, fn
        interim_transcript, matches ->
          if interim_transcript in expected_interims,
            do: matches + 1,
            else: matches
      end)

    assert matches / length(expected_interims) >= 0.9
  end

  defp assert_transcript(expected_transcript, end_event \\ true) do
    capture_speech_events(end_event)

    assert_receive {:response, %StreamingRecognizeResponse{results: results}}, 5000
    assert [%StreamingRecognitionResult{alternatives: alternative}] = results
    assert [%SpeechRecognitionAlternative{transcript: transcript}] = alternative
    assert String.downcase(transcript) == String.downcase(expected_transcript)
  end

  defp capture_speech_events(end_event) do
    assert_receive {:response,
                    %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                   5000

    if end_event do
      assert_receive {:response,
                      %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_END}},
                     5000
    end
  end

  # ===================== GenServer Tests =====================

  describe "Monitor" do
    test "stream server is closed if caller is shut down" do
      target = self()

      {:ok, client_pid} =
        Task.start(fn ->
          {:ok, server} = TranscriptionServer.start_link(target: self())
          send(target, {:server, server})
        end)

      assert_receive {:server, server}, 5000

      Process.monitor(server)
      Process.exit(client_pid, :normal)
      assert_receive {:DOWN, _, :process, ^server, :noproc}, 5000
    end
  end

  describe "get_or_start_stream/1" do
    test "starts a new stream if there's no current one" do
      recognizer = Fixtures.recognizer()
      {:ok, server_pid} = TranscriptionServer.start_link(target: self(), recognizer: recognizer)
      assert %Stream{} = TranscriptionServer.get_or_start_stream(server_pid)
    end

    test "takes the previous stream if there's one opened" do
      recognizer = Fixtures.recognizer()
      {:ok, server_pid} = TranscriptionServer.start_link(target: self(), recognizer: recognizer)
      assert %Stream{} = stream = TranscriptionServer.get_or_start_stream(server_pid)
      assert stream == TranscriptionServer.get_or_start_stream(server_pid)
    end
  end

  describe "send_audio_data" do
    test "sends audio data to the stream and starts fetching responses if it is the first request" do
      recognizer = Fixtures.recognizer()
      {:ok, server_pid} = TranscriptionServer.start_link(target: self(), recognizer: recognizer)
      assert %Stream{} = stream = TranscriptionServer.get_or_start_stream(server_pid)
      audio_data = Fixtures.audio_bytes()
      TranscriptionServer.send_audio_data(server_pid, audio_data)
      TranscriptionServer.end_stream(stream)

      assert_receive {:response,
                      %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                     5000

      assert_receive {:response, %Transcript{content: "Advent"}}, 5000
    end

    test "works as expected with interim results" do
      recognizer = Fixtures.recognizer()

      {:ok, server_pid} =
        TranscriptionServer.start_link(
          target: self(),
          recognizer: recognizer,
          interim_results: true
        )

      assert %Stream{} = TranscriptionServer.get_or_start_stream(server_pid)

      Fixtures.chunked_audio_bytes()
      |> Enum.each(&TranscriptionServer.send_audio_data(server_pid, &1))

      assert_receive {:response,
                      %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                     5000

      capture_and_assert_interim_transcripts()
    end

    defp capture_and_assert_interim_transcripts(interim_transcripts \\ []) do
      assert_receive {:response, %Transcript{} = transcript}, 5000
      interim_transcripts = interim_transcripts ++ [transcript]

      if transcript.is_final do
        interim_transcripts
        |> Enum.map(&(&1.content |> String.trim() |> String.downcase()))
        |> assert_interim_transcripts()

        # Final one
        transcript
      else
        capture_and_assert_interim_transcripts(interim_transcripts)
      end
    end

    # This checks for 88% accuracy, as the interim results are not deterministic
    defp assert_interim_transcripts(interim_transcripts) do
      expected_interims =
        Fixtures.interim_results()
        |> Enum.map(&(String.trim(&1) |> String.downcase()))

      matches =
        interim_transcripts
        |> Enum.reduce(0, fn
          interim_transcript, matches ->
            if interim_transcript in expected_interims,
              do: matches + 1,
              else: matches
        end)

      assert matches / length(expected_interims) >= 0.88
    end

    test "returns an error if the audio is too large" do
      recognizer = Fixtures.recognizer()
      {:ok, server_pid} = TranscriptionServer.start_link(target: self(), recognizer: recognizer)
      assert %Stream{} = TranscriptionServer.get_or_start_stream(server_pid)
      audio_data = Fixtures.full_audio_bytes()

      TranscriptionServer.send_audio_data(server_pid, audio_data)

      assert_receive {:response,
                      %GRPC.RPCError{
                        message: "Audio chunk can be of a a maximum of 25600 bytes" <> _
                      }},
                     5000
    end
  end

  describe "process_audio/2" do
    test "correcly starts a stream and process the audio" do
      recognizer = Fixtures.recognizer()
      {:ok, server_pid} = TranscriptionServer.start_link(target: self(), recognizer: recognizer)
      audio_data = Fixtures.audio_bytes()
      stream = TranscriptionServer.process_audio(server_pid, audio_data)
      TranscriptionServer.end_stream(stream)

      assert_receive {:response,
                      %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                     5000

      assert_receive {:response, %Transcript{content: "Advent"}}, 5000
    end

    test "starts a new stream if the previous one is closed and process the audio" do
      recognizer = Fixtures.recognizer()
      {:ok, server_pid} = TranscriptionServer.start_link(target: self(), recognizer: recognizer)
      audio_data = Fixtures.audio_bytes()

      # Processes first audio
      stream = TranscriptionServer.process_audio(server_pid, audio_data)
      TranscriptionServer.end_stream(stream)

      assert_receive {:response,
                      %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                     5000

      assert_receive {:response, %Transcript{content: "Advent"}}, 5000

      # Processes second audio
      new_stream = TranscriptionServer.process_audio(server_pid, audio_data)
      TranscriptionServer.end_stream(new_stream)

      assert_receive {:response,
                      %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                     5000

      assert_receive {:response, %Transcript{content: "Advent"}}, 5000
    end
  end

  # Careful when running these, since they'll cost you money
  describe "Load Tests" do
    @describetag :load_test
    test "can open 50 sessions at the same time without issue" do
      number_of_sessions = 50

      target = self()
      audio_data = Fixtures.audio_bytes()

      tasks =
        for _ <- 1..number_of_sessions do
          Task.async(fn ->
            recognizer = Fixtures.recognizer()

            {:ok, server_pid} =
              TranscriptionServer.start_link(target: target, recognizer: recognizer)

            stream = TranscriptionServer.process_audio(server_pid, audio_data)
            TranscriptionServer.end_stream(stream)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      for _ <- 1..number_of_sessions do
        assert_receive {:response,
                        %StreamingRecognizeResponse{speech_event_type: :SPEECH_ACTIVITY_BEGIN}},
                       5000

        assert_receive {:response, %Transcript{content: "Advent"}}, 5000
      end
    end
  end
end
