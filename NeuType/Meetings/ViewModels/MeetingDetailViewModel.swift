import Foundation

enum MeetingDetailTab: String, CaseIterable, Equatable {
    case transcript
    case summary

    static let displayOrder: [MeetingDetailTab] = [.summary, .transcript]

    var title: String {
        switch self {
        case .transcript:
            return "文字记录"
        case .summary:
            return "总结和待办"
        }
    }
}

enum MeetingTranscriptState: Equatable {
    case unprocessed
    case processing
    case completed
    case failed(message: String)
}

enum MeetingSummaryState: Equatable {
    case blocked(message: String)
    case unconfigured
    case unsubmitted
    case processing(status: MeetingSummaryStatus)
    case completed
    case failed(message: String)
}

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published private(set) var meeting: MeetingRecord?
    @Published private(set) var segments: [MeetingTranscriptSegment] = []
    @Published var activeTab: MeetingDetailTab = .transcript
    @Published var searchText = ""
    @Published private(set) var isTranscriptOperationInFlight = false

    let playbackCoordinator: MeetingPlaybackCoordinator

    private let meetingID: UUID
    private let store: MeetingRecordStore
    private let transcriptionService: MeetingTranscribing
    private let summaryService: MeetingSummarizing
    private let summaryConfigProvider: MeetingSummaryConfigProviding
    private var recordsDidChangeObserver: NSObjectProtocol?
    private var isSummaryOperationInFlight = false
    private var autoResumeFingerprint: String?

    init(
        meetingID: UUID,
        audioURL: URL,
        store: MeetingRecordStore = .shared,
        transcriptionService: MeetingTranscribing = MeetingTranscriptionService(),
        summaryService: MeetingSummarizing = MeetingSummaryService(),
        summaryConfigProvider: MeetingSummaryConfigProviding = AppPreferences.shared,
        playbackCoordinator: MeetingPlaybackCoordinator? = nil
    ) {
        self.meetingID = meetingID
        self.store = store
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        self.summaryConfigProvider = summaryConfigProvider
        self.playbackCoordinator = playbackCoordinator ?? MeetingPlaybackCoordinator(audioURL: audioURL)
        recordsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .meetingRecordsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                try? await self?.reload()
            }
        }
    }

    deinit {
        if let recordsDidChangeObserver {
            NotificationCenter.default.removeObserver(recordsDidChangeObserver)
        }
    }

    func load() async throws {
        try await reload(resetActiveTab: true)
    }

    func reload(resetActiveTab: Bool = false) async throws {
        let previousMeeting = meeting
        meeting = try await store.fetchMeeting(id: meetingID)
        segments = try await store.fetchSegments(meetingID: meetingID)
        playbackCoordinator.setSegments(segments)
        if let meeting {
            syncActiveTab(previousMeeting: previousMeeting, currentMeeting: meeting, resetActiveTab: resetActiveTab)
        }
        if let meeting {
            if [.completed, .failed, .unsubmitted].contains(meeting.summaryStatus) {
                isSummaryOperationInFlight = false
                autoResumeFingerprint = nil
            } else {
                resumeSummaryIfNeeded(for: meeting)
            }
        }
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

    func processTranscript() async {
        guard let meeting else { return }

        do {
            isTranscriptOperationInFlight = true
            defer { isTranscriptOperationInFlight = false }
            MeetingLog.info("Transcript processing start meetingID=\(meetingID)")
            try await store.updateMeetingStatus(
                meetingID: meetingID,
                status: .processing,
                progress: 0,
                transcriptPreview: ""
            )
            updateMeetingLocally(status: .processing, progress: 0, transcriptPreview: "")

            try await transcriptionService.transcribe(meetingID: meetingID, audioURL: meeting.audioURL)
            try await reload()
            MeetingLog.info("Transcript processing completed meetingID=\(meetingID)")
            if summaryConfigProvider.meetingSummaryConfig.isConfigured {
                Task {
                    do {
                        isSummaryOperationInFlight = true
                        defer { isSummaryOperationInFlight = false }
                        try await summaryService.submitMeeting(meetingID: meetingID)
                        try await reload()
                    } catch {
                        MeetingLog.error("Meeting summary auto-submit failed meetingID=\(meetingID) error=\(error.localizedDescription)")
                    }
                }
            }
        } catch {
            isTranscriptOperationInFlight = false
            let message = error.localizedDescription
            try? await store.updateMeetingStatus(
                meetingID: meetingID,
                status: .failed,
                progress: 0,
                transcriptPreview: message
            )
            updateMeetingLocally(status: .failed, progress: 0, transcriptPreview: message)
            MeetingLog.error(
                "Transcript processing failed meetingID=\(meetingID) errorType=\(String(describing: type(of: error))) error=\(message)"
            )
        }
    }

    func startTranscriptProcessing() {
        guard let meeting else { return }
        guard meeting.status == .unprocessed || meeting.status == .failed else { return }
        guard !isTranscriptOperationInFlight else { return }

        isTranscriptOperationInFlight = true
        updateMeetingLocally(status: .processing, progress: 0, transcriptPreview: "")
        MeetingLog.info("Transcript start button tapped meetingID=\(meetingID)")

        Task { [weak self] in
            await self?.processTranscript()
        }
    }

    func processSummary() async {
        guard let meeting else { return }
        guard meeting.status == .completed else { return }
        guard summaryConfigProvider.meetingSummaryConfig.isConfigured else { return }

        do {
            isSummaryOperationInFlight = true
            autoResumeFingerprint = nil
            defer { isSummaryOperationInFlight = false }
            try await store.updateSummaryStatus(meetingID: meetingID, status: .received)
            updateMeetingSummaryLocally(status: .received, errorMessage: "")
            MeetingLog.info("Meeting summary processing start meetingID=\(meetingID)")
            try await summaryService.submitMeeting(meetingID: meetingID)
            try await reload()
            activeTab = .summary
            MeetingLog.info("Meeting summary processing completed meetingID=\(meetingID)")
        } catch {
            let message = error.localizedDescription
            try? await store.updateSummaryStatus(
                meetingID: meetingID,
                status: .failed,
                errorMessage: message
            )
            updateMeetingSummaryLocally(status: .failed, errorMessage: message)
            MeetingLog.error("Meeting summary processing failed meetingID=\(meetingID) error=\(message)")
        }
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

    var transcriptState: MeetingTranscriptState {
        if isTranscriptOperationInFlight {
            return .processing
        }
        guard let meeting else { return .processing }

        switch meeting.status {
        case .unprocessed:
            return .unprocessed
        case .processing, .recording:
            return .processing
        case .completed:
            return .completed
        case .failed:
            return .failed(message: meeting.transcriptPreview)
        }
    }

    var summaryState: MeetingSummaryState {
        guard let meeting else { return .processing(status: .received) }
        guard meeting.status == .completed else {
            return .blocked(message: "请先完成文字记录处理，再提交到服务端生成会议总结。")
        }
        guard summaryConfigProvider.meetingSummaryConfig.isConfigured else {
            return .unconfigured
        }

        switch meeting.summaryStatus {
        case .unsubmitted:
            return .unsubmitted
        case .received, .queued, .processing:
            return .processing(status: meeting.summaryStatus)
        case .completed:
            return .completed
        case .failed:
            return .failed(message: meeting.summaryErrorMessage)
        }
    }

    var summaryResult: MeetingSummaryResult? {
        meeting?.decodedSummaryResult
    }

    var transcriptProcessingMessage: String {
        let message = meeting?.transcriptPreview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "正在调用转写服务生成文字记录和说话人分段，请稍候。" : message
    }

    var transcriptProgress: Float {
        max(0, min(meeting?.progress ?? 0, 1))
    }

    var transcriptRequestLogs: [RequestLogEntry] {
        Array(
            RequestLogStore.shared.entries
                .filter { $0.kind == .asr }
                .reversed()
                .prefix(20)
        )
    }

    var summaryText: String {
        meeting?.summaryText ?? ""
    }

    var summaryFullText: String {
        guard let meeting else { return "" }
        if !meeting.summaryFullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return meeting.summaryFullText
        }
        return meeting.summaryText
    }

    var shareURL: URL? {
        guard let raw = meeting?.summaryShareURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
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

    private func resumeSummaryIfNeeded(for meeting: MeetingRecord) {
        guard meeting.status == .completed else { return }
        guard summaryConfigProvider.meetingSummaryConfig.isConfigured else { return }
        guard [.received, .queued, .processing].contains(meeting.summaryStatus) else { return }
        guard !meeting.summaryJobID.isEmpty else { return }
        guard !isSummaryOperationInFlight else { return }
        let fingerprint = summaryResumeFingerprint(for: meeting)
        guard autoResumeFingerprint != fingerprint else { return }

        isSummaryOperationInFlight = true
        autoResumeFingerprint = fingerprint
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSummaryOperationInFlight = false }
            do {
                MeetingLog.info("Meeting summary resume requested meetingID=\(meetingID) jobID=\(meeting.summaryJobID)")
                try await summaryService.resumeMeeting(meetingID: meetingID)
            } catch {
                let message = error.localizedDescription
                autoResumeFingerprint = nil
                try? await store.updateSummaryStatus(
                    meetingID: meetingID,
                    status: .failed,
                    errorMessage: message
                )
                updateMeetingSummaryLocally(status: .failed, errorMessage: message)
                MeetingLog.error("Meeting summary resume failed meetingID=\(meetingID) error=\(message)")
            }
        }
    }

    private func updateMeetingLocally(
        status: MeetingRecordStatus,
        progress: Float,
        transcriptPreview: String
    ) {
        guard var meeting else { return }
        meeting.status = status
        meeting.progress = progress
        meeting.transcriptPreview = transcriptPreview
        self.meeting = meeting
    }

    private func updateMeetingSummaryLocally(
        status: MeetingSummaryStatus,
        errorMessage: String
    ) {
        guard var meeting else { return }
        meeting.summaryStatus = status
        meeting.summaryErrorMessage = errorMessage
        self.meeting = meeting
    }

    private func syncActiveTab(
        previousMeeting: MeetingRecord?,
        currentMeeting: MeetingRecord,
        resetActiveTab: Bool
    ) {
        if resetActiveTab {
            activeTab = preferredTab(for: currentMeeting)
            return
        }

        if currentMeeting.status != .completed {
            activeTab = .transcript
            return
        }

        let summaryIsAvailable = [.received, .queued, .processing, .completed].contains(currentMeeting.summaryStatus)
        let summaryJustBecameAvailable = ![.received, .queued, .processing, .completed].contains(previousMeeting?.summaryStatus ?? .unsubmitted)
            && summaryIsAvailable
        let summaryJustCompleted = previousMeeting?.summaryStatus != .completed && currentMeeting.summaryStatus == .completed

        if summaryJustBecameAvailable || summaryJustCompleted {
            activeTab = .summary
        }
    }

    private func preferredTab(for meeting: MeetingRecord) -> MeetingDetailTab {
        if meeting.status == .completed,
           [.received, .queued, .processing, .completed].contains(meeting.summaryStatus) {
            return .summary
        }
        return .transcript
    }

    private func summaryResumeFingerprint(for meeting: MeetingRecord) -> String {
        "\(meeting.summaryJobID)|\(meeting.summaryStatus.rawValue)"
    }
}
