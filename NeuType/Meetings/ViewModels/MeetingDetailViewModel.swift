import Foundation

enum MeetingDetailTab: String, CaseIterable, Equatable {
    case audio
    case transcript

    var title: String {
        switch self {
        case .audio:
            return "录制音频"
        case .transcript:
            return "文字记录"
        }
    }
}

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published private(set) var meeting: MeetingRecord?
    @Published private(set) var segments: [MeetingTranscriptSegment] = []
    @Published var activeTab: MeetingDetailTab = .audio
    @Published var searchText = ""

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
        playbackCoordinator.setSegments(segments)
        activeTab = .audio
    }

    func playSegment(_ segment: MeetingTranscriptSegment) {
        playbackCoordinator.seek(to: segment.startTime)
        playbackCoordinator.play()
    }

    func seekPlayback(to time: TimeInterval) {
        playbackCoordinator.seek(to: time)
    }

    func togglePlayback() {
        if playbackCoordinator.isPlaying {
            playbackCoordinator.pause()
        } else {
            playbackCoordinator.play()
        }
    }

    func renameMeeting(to proposedTitle: String) async throws {
        guard var meeting else { return }

        let title = Self.normalizedTitle(proposedTitle, fallbackDate: meeting.createdAt)
        try await store.updateMeetingTitle(meetingID: meetingID, title: title)
        meeting.title = title
        self.meeting = meeting
    }

    var filteredSegments: [MeetingTranscriptSegment] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return segments
        }

        return segments.filter { segment in
            segment.speakerLabel.localizedCaseInsensitiveContains(trimmedQuery)
                || segment.text.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private static func normalizedTitle(_ proposedTitle: String, fallbackDate: Date) -> String {
        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: fallbackDate)
    }
}
