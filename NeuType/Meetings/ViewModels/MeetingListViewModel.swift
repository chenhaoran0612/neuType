import Foundation

@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []

    private let store: MeetingRecordStore

    init(store: MeetingRecordStore = .shared) {
        self.store = store
    }

    func load() async {
        meetings = (try? await store.fetchMeetings()) ?? []
    }
}
