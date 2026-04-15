import Foundation

@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []

    private let store: MeetingRecordStore
    private let audioImporter: MeetingAudioImporting
    private var recordsDidChangeObserver: NSObjectProtocol?

    init(
        store: MeetingRecordStore = .shared,
        audioImporter: MeetingAudioImporting = DefaultMeetingAudioImporter()
    ) {
        self.store = store
        self.audioImporter = audioImporter
        recordsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .meetingRecordsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    deinit {
        if let recordsDidChangeObserver {
            NotificationCenter.default.removeObserver(recordsDidChangeObserver)
        }
    }

    func load() async {
        meetings = (try? await store.fetchMeetings()) ?? []
    }

    func meeting(id: UUID?) -> MeetingRecord? {
        guard let id else { return nil }
        return meetings.first(where: { $0.id == id })
    }

    func deleteMeeting(id: UUID) async {
        do {
            try await store.deleteMeeting(meetingID: id)
            meetings.removeAll { $0.id == id }
        } catch {
            await load()
        }
    }

    func importAudio(from sourceURL: URL) async throws -> UUID {
        let importedAudioURL = try audioImporter.importAudio(from: sourceURL)
        let meetingID = UUID()
        let createdAt = Date()
        let meeting = MeetingRecord(
            id: meetingID,
            createdAt: createdAt,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            audioFileName: importedAudioURL.lastPathComponent,
            transcriptPreview: "",
            duration: 0,
            status: .unprocessed,
            progress: 0
        )
        try await store.insertMeeting(meeting, segments: [])
        await load()
        return meetingID
    }
}
