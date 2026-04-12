import XCTest
@testable import NeuType

final class MeetingDetailViewModelTests: XCTestCase {
    @MainActor
    func testDefaultsToAudioTabAfterLoad() async throws {
        let meeting = MeetingRecord.fixture(status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "说话人A",
                startTime: 3,
                endTime: 5,
                text: "这是2.5。"
            )
        ])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertEqual(viewModel.activeTab, .audio)
        XCTAssertEqual(viewModel.segments.count, 1)
    }

    @MainActor
    func testTranscriptSearchFiltersSegments() async throws {
        let meeting = MeetingRecord.fixture(status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "说话人A",
                startTime: 3,
                endTime: 5,
                text: "这是2.5。"
            ),
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 1,
                speakerLabel: "说话人B",
                startTime: 9,
                endTime: 12,
                text: "但是我知道一个秘密。"
            )
        ])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()
        viewModel.searchText = "秘密"

        XCTAssertEqual(viewModel.filteredSegments.map(\.sequence), [1])
    }

    @MainActor
    func testRenameMeetingPersistsUpdatedTitle() async throws {
        let meeting = MeetingRecord.fixture(title: "2026-04-12 10:41", status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()
        try await viewModel.renameMeeting(to: "客户周会")

        XCTAssertEqual(viewModel.meeting?.title, "客户周会")
        let savedMeeting = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(savedMeeting?.title, "客户周会")
    }

    @MainActor
    func testRenameMeetingFallsBackToDefaultTitleWhenEmpty() async throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        components.year = 2026
        components.month = 4
        components.day = 12
        components.hour = 10
        components.minute = 41
        let createdAt = try XCTUnwrap(components.date)
        let meeting = MeetingRecord.fixture(
            createdAt: createdAt,
            title: "2026-04-12 10:41",
            status: .completed
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()
        try await viewModel.renameMeeting(to: "   ")

        XCTAssertEqual(viewModel.meeting?.title, "2026-04-12 10:41")
        let savedMeeting = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(savedMeeting?.title, "2026-04-12 10:41")
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
