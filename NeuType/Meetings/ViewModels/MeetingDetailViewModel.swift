import Foundation

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published private(set) var meeting: MeetingRecord?
    @Published private(set) var segments: [MeetingTranscriptSegment] = []

    let playbackCoordinator: MeetingPlaybackCoordinator

    private let meetingID: UUID
    private let store: MeetingRecordStore

    init(
        meetingID: UUID,
        audioURL: URL,
        store: MeetingRecordStore = .shared,
        playbackCoordinator: MeetingPlaybackCoordinator? = nil
    ) {
        self.meetingID = meetingID
        self.store = store
        self.playbackCoordinator = playbackCoordinator ?? MeetingPlaybackCoordinator(audioURL: audioURL)
    }

    func load() async throws {
        meeting = try await store.fetchMeeting(id: meetingID)
        segments = try await store.fetchSegments(meetingID: meetingID)
    }

    func playSegment(_ segment: MeetingTranscriptSegment) {
        playbackCoordinator.seek(to: segment.startTime)
        playbackCoordinator.play()
        playbackCoordinator.updateCurrentTime(segment.startTime, segments: segments)
    }
}
