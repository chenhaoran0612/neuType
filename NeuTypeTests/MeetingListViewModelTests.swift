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

    @MainActor
    func testImportAudioCreatesUnprocessedMeetingAndCopiesFile() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let meetingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importer = DefaultMeetingAudioImporter(meetingsDirectory: meetingsDirectory)
        let store = try MeetingRecordStore.inMemory()
        let viewModel = MeetingListViewModel(store: store, audioImporter: importer)

        let importedMeetingID = try await viewModel.importAudio(from: sourceURL)

        let meeting = try await store.fetchMeeting(id: importedMeetingID)
        XCTAssertEqual(meeting?.status, .unprocessed)
        XCTAssertEqual(meeting?.title, sourceURL.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingsDirectory.appendingPathComponent(sourceURL.lastPathComponent).path))
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
