import XCTest
@testable import NeuType

final class VibeVoiceRunnerClientTests: XCTestCase {
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
}
