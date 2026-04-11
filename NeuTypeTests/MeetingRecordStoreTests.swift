import XCTest
@testable import NeuType

final class MeetingRecordStoreTests: XCTestCase {
    func testInsertMeetingAndFetchSegments() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = MeetingRecord.fixture(status: .processing)
        let segments = [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1"
            ),
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 1,
                speakerLabel: "Speaker 2"
            ),
        ]

        try await store.insertMeeting(meeting, segments: segments)

        let loaded = try await store.fetchMeeting(id: meeting.id)
        let loadedSegments = try await store.fetchSegments(meetingID: meeting.id)

        XCTAssertEqual(loaded?.id, meeting.id)
        XCTAssertEqual(loadedSegments.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
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

private extension MeetingTranscriptSegment {
    static func fixture(
        id: UUID = UUID(),
        meetingID: UUID,
        sequence: Int,
        speakerLabel: String,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 1,
        text: String = "segment"
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            meetingID: meetingID,
            sequence: sequence,
            speakerLabel: speakerLabel,
            startTime: startTime,
            endTime: endTime,
            text: text
        )
    }
}
