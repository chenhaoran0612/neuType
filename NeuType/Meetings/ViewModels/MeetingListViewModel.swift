import Foundation

@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []

    private let store: MeetingRecordStore
    private var recordsDidChangeObserver: NSObjectProtocol?

    init(store: MeetingRecordStore = .shared) {
        self.store = store
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
}
