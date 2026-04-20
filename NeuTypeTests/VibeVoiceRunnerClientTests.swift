import AVFoundation
import Foundation
import XCTest
@testable import NeuType

final class VibeVoiceRunnerClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        URLProtocolStub.requestHandlers = []
        URLProtocolStub.recordedRequests = []
    }

    func testTranscribeUploadsAudioQueuesJobAndParsesSpeakerSegments() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "/gradio_api",
                apiKey: "vv_test_key",
                contextInfo: "OpenAI\nMicrosoft",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-123","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":1.5,\"Speaker\":0,\"Content\":\"hello\"},{\"Start\":1.5,\"End\":3,\"Speaker\":1,\"Content\":\"world\"}]"},"finish_reason":"stop"}]}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config
        )

        let result = try await client.transcribe(audioURL: audioURL, hotwords: ["VibeVoice"], progress: nil)

        XCTAssertEqual(result.fullText, "hello world")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(result.segments[1].speakerLabel, "Speaker 2")

        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 0])
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 600)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer vv_test_key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "vv_test_key")

        let requestBody = try XCTUnwrap(
            request.httpBody ?? request.httpBodyStream.flatMap(Self.readStream)
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "vibevoice")
        XCTAssertEqual(payload["temperature"] as? Double, 0.0)
        XCTAssertEqual(payload["max_tokens"] as? Int, 4096)
        XCTAssertEqual(payload["stream"] as? Bool, true)

        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")

        let userMessage = try XCTUnwrap(messages[safe: 1])
        let content = try XCTUnwrap(userMessage["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)

        let audioPart = try XCTUnwrap(content[safe: 0])
        XCTAssertEqual(audioPart["type"] as? String, "audio_url")
        let audioURLPayload = try XCTUnwrap(audioPart["audio_url"] as? [String: Any])
        let dataURL = try XCTUnwrap(audioURLPayload["url"] as? String)
        XCTAssertTrue(dataURL.hasPrefix("data:audio/wav;base64,"))

        let textPart = try XCTUnwrap(content[safe: 1])
        XCTAssertEqual(textPart["type"] as? String, "text")
        let prompt = try XCTUnwrap(textPart["text"] as? String)
        XCTAssertTrue(prompt.contains("OpenAI"))
        XCTAssertTrue(prompt.contains("Microsoft"))
        XCTAssertTrue(prompt.contains("VibeVoice"))
        XCTAssertTrue(prompt.contains("Please transcribe"))
    }

    func testTranscribeIncludesRepetitionPenaltyInMeetingVibeVoiceRequest() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                apiKey: "vv_test_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.12
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-penalty","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":1,\"Speaker\":0,\"Content\":\"hello\"}]"},"finish_reason":"stop"}]}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(session: session, configProvider: config)
        _ = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 0])
        let requestBody = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.flatMap(Self.readStream))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])

        XCTAssertEqual(payload["repetition_penalty"] as? Double, 1.12)
    }

    func testTranscribeReportsProgressStagesInOrder() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "/gradio_api",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-456","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":1,\"Speaker\":0,\"Content\":\"hello\"}]"},"finish_reason":"stop"}]}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(session: session, configProvider: config)
        let recorder = ProgressRecorder()

        _ = try await client.transcribe(audioURL: audioURL, hotwords: []) { progress in
            await recorder.append(progress)
        }

        let recordedStages = await recorder.progresses.map(\.stage)
        XCTAssertEqual(
            recordedStages,
            [.preparingAudio, .analyzingAudio, .uploadingAudio, .transcribing, .finalizing]
        )
    }

    func testTranscribeReportsChunkLevelProgressMessagesAndFractions() async throws {
        let audioURL = try Self.makeSilentWAV(duration: 0.03, sampleRate: 8_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = (0..<3).map { index in
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    """
                    {"id":"chatcmpl-progress-\(index)","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\\"Start\\":0,\\"End\\":0.01,\\"Speaker\\":0,\\"Content\\":\\"chunk-\(index)\\"}]"},"finish_reason":"stop"}]}
                    """.data(using: .utf8)!
                )
            }
        }

        let recorder = ProgressRecorder()
        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config,
            chunkDuration: 0.01
        )

        _ = try await client.transcribe(audioURL: audioURL, hotwords: []) { progress in
            await recorder.append(progress)
        }

        let transcribingProgresses = await recorder.progresses.filter { $0.stage == .transcribing }
        XCTAssertEqual(transcribingProgresses.map(\.completedUnitCount), [0, 1, 2])
        XCTAssertEqual(transcribingProgresses.map(\.totalUnitCount), [3, 3, 3])
        XCTAssertTrue(transcribingProgresses[0].message.contains("1 / 3"))
        XCTAssertTrue(transcribingProgresses[1].message.contains("2 / 3"))
        XCTAssertTrue(transcribingProgresses[2].message.contains("3 / 3"))
        XCTAssertTrue(
            zip(transcribingProgresses, transcribingProgresses.dropFirst()).allSatisfy {
                $0.fractionCompleted < $1.fractionCompleted
            }
        )
    }

    func testTranscribeSkipsTruncatedNoiseOnlyChunkAndContinues() async throws {
        let audioURL = try Self.makeSilentWAV(duration: 0.02, sampleRate: 8_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-noise","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":10,\"Speaker\":0,\"Content\":\"[Noise]\"},{\"Start\":10,\"End\":20,\"Content\":\"[Environmental Sounds]\"}"},"finish_reason":"length"}]}
                    """#.data(using: .utf8)!
                )
            },
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-speech","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":0.01,\"Speaker\":0,\"Content\":\"hello\"}]"},"finish_reason":"stop"}]}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config,
            chunkDuration: 0.01
        )

        let result = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)

        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2)
        XCTAssertEqual(result.fullText, "hello")
        XCTAssertEqual(result.segments.map(\.text), ["hello"])
    }

    func testTranscribeDoesNotRetryTimedOutChunkBelowTwentyMinutes() async throws {
        let audioURL = try Self.makeSilentWAV(duration: 12.1, sampleRate: 8_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { _ in
                throw URLError(.timedOut)
            },
        ]

        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config,
            chunkDuration: 30
        )

        do {
            _ = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }

        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)
    }

    func testTranscribeReturnsFriendlyTimeoutErrorWhenSmallChunkTimesOut() async throws {
        let audioURL = try Self.makeSilentWAV(duration: 2.0, sampleRate: 8_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { _ in
                throw URLError(.timedOut)
            },
        ]

        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config,
            chunkDuration: 30
        )

        do {
            _ = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    @MainActor
    func testTranscribeParsesStreamingSSEEventsAndLogsAllEvents() async throws {
        RequestLogStore.shared.clear()

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                apiKey: "vv_test_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    data: {"choices":[{"delta":{"content":"[{\"Start\":0,\"End\":1,\"Speaker\":0,\"Content\":\"hello "},"finish_reason":null}]}

                    data: {"choices":[{"delta":{"content":"world\"}]"},"finish_reason":"stop"}]}

                    data: [DONE]

                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(session: session, configProvider: config)
        let result = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)

        XCTAssertEqual(result.fullText, "hello world")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertTrue(RequestLogStore.shared.entries.contains { $0.message.contains("Meeting ASR stream <- {\"choices\"") })
        XCTAssertTrue(RequestLogStore.shared.entries.contains { $0.message.contains("Meeting ASR stream <- [DONE]") })
    }

    func testTranscribeUsesLegacyGradioPrefixCompatForChatCompletions() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "/gradio_api",
                contextInfo: "",
                maxNewTokens: 2048,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-789","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":1,\"Speaker\":0,\"Content\":\"hello\"}]"},"finish_reason":"stop"}]}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(session: session, configProvider: config)
        _ = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 0])
        XCTAssertEqual(request.url?.absoluteString, "http://workspace.featurize.cn:12930/v1/chat/completions")
    }

    func testTranscribeResolvesLargeMaxTokenSettingBelowModelContextLimit() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                contextInfo: "",
                maxNewTokens: 16384,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"id":"chatcmpl-999","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\"Start\":0,\"End\":1,\"Speaker\":0,\"Content\":\"hello\"}]"},"finish_reason":"stop"}]}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = VibeVoiceRunnerClient(session: session, configProvider: config)
        _ = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 0])
        let requestBody = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.flatMap(Self.readStream))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let promptText = "Please transcribe it with these keys: Start time, End time, Speaker ID, Content. Return JSON array only."
        let expectedMaxTokens = VibeVoiceRunnerClient.resolvedMaxTokens(
            configuredMaxTokens: 16384,
            promptText: promptText
        )
        XCTAssertEqual(payload["max_tokens"] as? Int, expectedMaxTokens)
        XCTAssertLessThan(expectedMaxTokens, 16384)
    }

    func testTranscribeSplitsLongAudioAndOffsetsChunkTimelines() async throws {
        let audioURL = try Self.makeSilentWAV(duration: 0.03, sampleRate: 8_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = (0..<3).map { index in
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    """
                    {"id":"chatcmpl-chunk-\(index)","object":"chat.completion","model":"vibevoice","choices":[{"index":0,"message":{"role":"assistant","content":"[{\\"Start\\":0,\\"End\\":0.01,\\"Speaker\\":0,\\"Content\\":\\"chunk-\(index)\\"}]"},"finish_reason":"stop"}]}
                    """.data(using: .utf8)!
                )
            }
        }

        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config,
            chunkDuration: 0.01
        )
        let result = try await client.transcribe(audioURL: audioURL, hotwords: [], progress: nil)

        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 3)
        XCTAssertEqual(result.fullText, "chunk-0 chunk-1 chunk-2")
        XCTAssertEqual(result.segments.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(result.segments.map(\.startTime), [0, 0.01, 0.02])
        XCTAssertEqual(result.segments.map(\.endTime), [0.01, 0.02, 0.03])
    }

    func testDefaultChunkDurationIsFiveMinutes() {
        XCTAssertEqual(VibeVoiceRunnerClient.defaultChunkDurationForTesting(), 5 * 60)
    }

    func testAudioChunkingPrefersLowEnergyBoundaryNearChunkEdge() throws {
        let audioURL = try Self.makePatternedWAV(
            sampleRate: 8_000,
            segments: [
                (1.12, 0.7),
                (0.16, 0.0),
                (1.12, 0.7),
                (0.20, 0.0),
            ]
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let offsets = VibeVoiceRunnerClient.chunkTimeOffsetsForTesting(
            audioURL: audioURL,
            chunkDuration: 1.0
        )

        XCTAssertEqual(offsets.count, 3)
        guard offsets.count == 3 else { return }
        XCTAssertEqual(offsets[0], 0)
        XCTAssertGreaterThan(offsets[1], 1.05)
        XCTAssertLessThan(offsets[1], 1.30)
    }

    func testResolvedChunkDurationPreservesConfiguredDuration() throws {
        let audioURL = try Self.makeSilentWAV(duration: 60, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let resolved = VibeVoiceRunnerClient.resolvedChunkDuration(
            audioURL: audioURL,
            configuredChunkDuration: 300,
            targetRequestJSONBytes: 1_500_000
        )

        XCTAssertEqual(resolved, 300)
    }

    func testMergeSegmentsDropsDuplicateOverlapAndRenumbersSequences() {
        let merged = VibeVoiceRunnerClient.mergeSegmentsDroppingOverlapDuplicates([
            MeetingTranscriptionSegmentPayload(
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 5,
                text: "我们今天讨论项目安排"
            ),
            MeetingTranscriptionSegmentPayload(
                sequence: 1,
                speakerLabel: "Speaker 1",
                startTime: 4.2,
                endTime: 6,
                text: "我们今天讨论项目安排"
            ),
            MeetingTranscriptionSegmentPayload(
                sequence: 2,
                speakerLabel: "Speaker 2",
                startTime: 6,
                endTime: 8,
                text: "下周完成第一版"
            ),
        ])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.sequence), [0, 1])
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].endTime, 6)
        XCTAssertEqual(merged[0].text, "我们今天讨论项目安排")
        XCTAssertEqual(merged[1].text, "下周完成第一版")
    }

    func testDecodeResultFailsWhenAssistantJSONMissing() {
        XCTAssertThrowsError(
            try VibeVoiceRunnerClient.decodeResult(
                from: "assistant\nnot-json".data(using: .utf8)!
            )
        )
    }

    func testDecodeResultParsesOnlyBalancedJSONArray() throws {
        let payload = """
        --- ✅ Raw Output ---
        assistant
        [{"Start":0.0,"End":1.5,"Speaker":0,"Content":"hello"}]
        <div>ignored</div>
        """.data(using: .utf8)!

        let result = try VibeVoiceRunnerClient.decodeResult(from: payload)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.fullText, "hello")
    }

    func testDecodeResultParsesLowercaseChatCompletionSchema() throws {
        let payload = """
        [{"start_time":97.35,"end_time":117.15,"speaker_id":0,"text":"大家好"},{"start_time":117.15,"end_time":118.52,"speaker_id":1,"text":"继续"}]
        """.data(using: .utf8)!

        let result = try VibeVoiceRunnerClient.decodeResult(from: payload)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(result.segments[0].text, "大家好")
        XCTAssertEqual(result.segments[1].speakerLabel, "Speaker 2")
        XCTAssertEqual(result.fullText, "大家好 继续")
    }

    func testDecodeResultRepairsMojibakeFromStreamingPayload() throws {
        let payload = """
        [{"start_time":97.35,"end_time":117.15,"speaker_id":0,"text":"OKï¼ç¶åä»å¤©"}]
        """.data(using: .utf8)!

        let result = try VibeVoiceRunnerClient.decodeResult(from: payload)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, "OK，然后今天")
    }

    func testDecodeResultReturnsServiceNoSegmentsError() {
        let payload = """
        --- ✅ Raw Output ---
        assistant
        [Click] [Click]

        <div class='no-segments-container'>
            <p>❌ No audio segments available.</p>
            <p>This could happen if the model output doesn't contain valid time stamps.</p>
        </div>
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try VibeVoiceRunnerClient.decodeResult(from: payload)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No audio segments available. This could happen if the model output doesn't contain valid time stamps."
            )
        }
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func readStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }

        return data
    }

    private static func makeSilentWAV(duration: TimeInterval, sampleRate: Double) throws -> URL {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        var file: AVAudioFile? = try AVAudioFile(
            forWriting: audioURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file?.write(from: buffer)
        file = nil
        return audioURL
    }

    private static func makePatternedWAV(
        sampleRate: Double,
        segments: [(duration: TimeInterval, amplitude: Float)]
    ) throws -> URL {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let totalFrames = AVAudioFrameCount(segments.reduce(0) { $0 + Int($1.duration * sampleRate) })
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames

        let channel = buffer.floatChannelData![0]
        var writeIndex = 0
        for segment in segments {
            let frameCount = Int(segment.duration * sampleRate)
            for frame in 0..<frameCount {
                let sample = segment.amplitude == 0
                    ? Float.zero
                    : sin(Float(frame) * 0.08) * segment.amplitude
                channel[writeIndex] = sample
                writeIndex += 1
            }
        }

        var file: AVAudioFile? = try AVAudioFile(
            forWriting: audioURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file?.write(from: buffer)
        file = nil
        return audioURL
    }
}

private actor ProgressRecorder {
    private(set) var progresses: [MeetingTranscriptionProgress] = []

    func append(_ progress: MeetingTranscriptionProgress) {
        progresses.append(progress)
    }
}

private struct StubMeetingVibeVoiceConfigProvider: MeetingVibeVoiceConfigProviding {
    let config: MeetingVibeVoiceConfig

    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { config }
}

private final class URLProtocolStub: URLProtocol {
    static var requestHandlers: [(URLRequest) throws -> (HTTPURLResponse, Data)] = []
    static var recordedRequests: [URLRequest] = []

    static func makeHTTPURLResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recordedRequests.append(request)
        guard !Self.requestHandlers.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let handler = Self.requestHandlers.removeFirst()
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
