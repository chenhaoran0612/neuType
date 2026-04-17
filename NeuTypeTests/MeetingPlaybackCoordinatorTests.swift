import XCTest
@testable import NeuType

final class MeetingPlaybackCoordinatorTests: XCTestCase {
    @MainActor
    func testActiveSegmentMatchesPlaybackTime() {
        let segments = [
            MeetingTranscriptSegment.fixture(sequence: 0, startTime: 0, endTime: 2),
            MeetingTranscriptSegment.fixture(sequence: 1, startTime: 2, endTime: 5),
        ]
        let coordinator = MeetingPlaybackCoordinator(audioURL: URL(fileURLWithPath: "/tmp/demo.wav"))

        coordinator.updateCurrentTime(3.0, segments: segments)

        XCTAssertEqual(coordinator.activeSegmentSequence, 1)
    }
}

private extension MeetingTranscriptSegment {
    static func fixture(
        id: UUID = UUID(),
        meetingID: UUID = UUID(),
        sequence: Int,
        speakerLabel: String = "Speaker",
        startTime: TimeInterval,
        endTime: TimeInterval,
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
