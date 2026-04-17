import XCTest
@testable import NeuType

final class MeetingTranscriptionServiceTests: XCTestCase {
    func testTranscribeMeetingPersistsSegmentsAndPreview() async throws {
        let runner = StubVibeVoiceRunnerClient(result: .fixture())
        let store = try MeetingRecordStore.inMemory()
        let meeting = MeetingRecord.fixture(status: .processing)
        try await store.insertMeeting(meeting, segments: [])
        let service = MeetingTranscriptionService(runner: runner, store: store)

        try await service.transcribe(
            meetingID: meeting.id,
            audioURL: URL(fileURLWithPath: "/tmp/demo.wav")
        )

        let saved = try await store.fetchMeeting(id: meeting.id)
        let segments = try await store.fetchSegments(meetingID: meeting.id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.transcriptPreview, "hello world")
        XCTAssertEqual(segments.count, 2)
    }
}

private struct StubVibeVoiceRunnerClient: VibeVoiceRunning {
    let result: MeetingTranscriptionResult

    func transcribe(
        audioURL: URL,
        hotwords: [String],
        progress: (@Sendable (MeetingTranscriptionProgress) async -> Void)?
    ) async throws -> MeetingTranscriptionResult {
        result
    }
}

private extension MeetingTranscriptionResult {
    static func fixture() -> MeetingTranscriptionResult {
        MeetingTranscriptionResult(
            fullText: "hello world",
            segments: [
                MeetingTranscriptionSegmentPayload(
                    sequence: 0,
                    speakerLabel: "Speaker 1",
                    startTime: 0,
                    endTime: 1,
                    text: "hello"
                ),
                MeetingTranscriptionSegmentPayload(
                    sequence: 1,
                    speakerLabel: "Speaker 2",
                    startTime: 1,
                    endTime: 2,
                    text: "world"
                ),
            ]
        )
    }
}

private extension MeetingRecord {
    static func fixture(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String = "Meeting",
        audioFileName: String = "meeting.wav",
        transcriptPreview: String = "",
        duration: TimeInterval = 0,
        status: MeetingRecordStatus = .recording,
        progress: Float = 0
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            createdAt: createdAt,
            title: title,
            audioFileName: audioFileName,
            transcriptPreview: transcriptPreview,
            duration: duration,
            status: status,
            progress: progress
        )
    }
}
