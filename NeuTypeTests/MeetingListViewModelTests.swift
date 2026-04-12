import XCTest
@testable import NeuType

final class MeetingListViewModelTests: XCTestCase {
    @MainActor
    func testListLoadsMeetingsNewestFirst() async throws {
        let older = MeetingRecord.fixture(createdAt: Date(timeIntervalSince1970: 100))
        let newer = MeetingRecord.fixture(createdAt: Date(timeIntervalSince1970: 200))
        let store = try MeetingRecordStore.inMemory(seed: [older, newer])
        let viewModel = MeetingListViewModel(store: store)

        await viewModel.load()

        XCTAssertEqual(viewModel.meetings.first?.createdAt, newer.createdAt)
    }

    @MainActor
    func testDeleteMeetingRemovesItFromList() async throws {
        let first = MeetingRecord.fixture(createdAt: Date(timeIntervalSince1970: 100), audioFileName: "first.wav")
        let second = MeetingRecord.fixture(createdAt: Date(timeIntervalSince1970: 200), audioFileName: "second.wav")
        let store = try MeetingRecordStore.inMemory(seed: [first, second])
        let viewModel = MeetingListViewModel(store: store)

        await viewModel.load()
        await viewModel.deleteMeeting(id: second.id)

        XCTAssertEqual(viewModel.meetings.map(\.id), [first.id])
    }
}

private extension MeetingRecord {
    static func fixture(
        id: UUID = UUID(),
        createdAt: Date,
        title: String = "Meeting",
        audioFileName: String = "meeting.wav",
        transcriptPreview: String = "",
        duration: TimeInterval = 0,
        status: MeetingRecordStatus = .completed,
        progress: Float = 1
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
