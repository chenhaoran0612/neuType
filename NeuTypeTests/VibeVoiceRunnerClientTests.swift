import XCTest
@testable import NeuType

final class VibeVoiceRunnerClientTests: XCTestCase {
    func testRunnerEnvironmentDisablesProgressAndWarnings() {
        let environment = VibeVoiceRunnerClient.runnerEnvironment(base: [
            "VIBEVOICE_RUNNER_BACKEND": "mock",
        ])

        XCTAssertEqual(environment["VIBEVOICE_RUNNER_BACKEND"], "mock")
        XCTAssertEqual(environment["HF_HUB_DISABLE_PROGRESS_BARS"], "1")
        XCTAssertEqual(environment["TRANSFORMERS_NO_ADVISORY_WARNINGS"], "1")
        XCTAssertEqual(environment["TOKENIZERS_PARALLELISM"], "false")
        XCTAssertEqual(environment["PYTHONWARNINGS"], "ignore")
    }

    func testFailureMessageReturnsLastMeaningfulLine() {
        let errorData = """
        Warning: You are sending unauthenticated requests to the HF Hub.
        Loading weights: 56%|████|
        No module named 'accelerate'
        """.data(using: .utf8)!

        XCTAssertEqual(
            VibeVoiceRunnerClient.failureMessage(from: errorData),
            "No module named 'accelerate'"
        )
    }

    func testDecodeStructuredRunnerOutput() throws {
        let data = """
        {
          "full_text": "hello world",
          "segments": [
            {"sequence": 0, "speaker_label": "Speaker 1", "start_time": 0.0, "end_time": 1.2, "text": "hello"},
            {"sequence": 1, "speaker_label": "Speaker 2", "start_time": 1.2, "end_time": 2.0, "text": "world"}
          ]
        }
        """.data(using: .utf8)!

        let result = try VibeVoiceRunnerClient.decodeResult(from: data)

        XCTAssertEqual(result.fullText, "hello world")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
    }

    func testTranscribeRunsPythonRunnerContract() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                pythonPath: "/usr/bin/python3",
                runnerPath: "/Users/chenhaoran/code/NeuType/Scripts/vibevoice_asr_runner.py",
                modelID: "microsoft/VibeVoice-ASR-HF"
            )
        )
        let client = VibeVoiceRunnerClient(
            configProvider: config,
            configureProcess: { process in
                process.environment = [
                    "VIBEVOICE_RUNNER_BACKEND": "mock",
                ]
            }
        )

        let result = try await client.transcribe(audioURL: audioURL, hotwords: ["NeuType"])

        XCTAssertEqual(result.fullText, "Mock transcript for NeuType")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
    }
}

private struct StubMeetingVibeVoiceConfigProvider: MeetingVibeVoiceConfigProviding {
    let config: MeetingVibeVoiceConfig

    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { config }
}
