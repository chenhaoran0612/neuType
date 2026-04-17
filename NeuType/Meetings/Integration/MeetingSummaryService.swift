import Foundation

protocol MeetingSummarizing {
    func submitMeeting(meetingID: UUID) async throws
    func resumeMeeting(meetingID: UUID) async throws
}

private actor MeetingSummaryPollingRegistry {
    private var activeTokens: [UUID: UUID] = [:]

    func begin(meetingID: UUID) -> UUID? {
        guard activeTokens[meetingID] == nil else { return nil }
        let token = UUID()
        activeTokens[meetingID] = token
        return token
    }

    func end(meetingID: UUID, token: UUID) {
        guard activeTokens[meetingID] == token else { return }
        activeTokens.removeValue(forKey: meetingID)
    }
}

final class MeetingSummaryService: MeetingSummarizing {
    private static let pollingRegistry = MeetingSummaryPollingRegistry()

    private let client: MeetingSummaryClientProtocol
    private let store: MeetingRecordStore
    private let pollInterval: Duration
    private let maxPollCount: Int
    private let pollsInBackground: Bool

    init(
        client: MeetingSummaryClientProtocol = MeetingSummaryClient(),
        store: MeetingRecordStore = .shared,
        pollInterval: Duration = .seconds(3),
        maxPollCount: Int = 120,
        pollsInBackground: Bool = true
    ) {
        self.client = client
        self.store = store
        self.pollInterval = pollInterval
        self.maxPollCount = maxPollCount
        self.pollsInBackground = pollsInBackground
    }

    func submitMeeting(meetingID: UUID) async throws {
        guard let meeting = try await store.fetchMeeting(id: meetingID) else {
            throw MeetingSummaryClientError.invalidResponse
        }

        let segments = try await store.fetchSegments(meetingID: meetingID)
        guard meeting.status == .completed else {
            throw MeetingSummaryClientError.requestFailed(statusCode: 0, body: "请先完成文字记录处理。")
        }

        let transcriptText = MeetingExportFormatter.transcriptText(
            meetingTitle: meeting.title,
            meetingDate: meeting.createdAt,
            segments: segments
        )

        let submissionIdentity = Self.submissionIdentity(for: meeting)
        let payload = MeetingSummarySubmissionPayload(
            externalMeetingID: submissionIdentity.externalMeetingID,
            idempotencyKey: submissionIdentity.idempotencyKey,
            meetingTitle: meeting.title,
            meetingStartedAt: meeting.createdAt,
            meetingEndedAt: meeting.createdAt.addingTimeInterval(max(meeting.duration, 0)),
            meetingTimeZone: TimeZone.current.identifier,
            language: Self.meetingLanguage(),
            transcriptFileName: MeetingExportFormatter.audioFileName(
                meetingTitle: meeting.title,
                originalFileName: meeting.audioFileName
            ).replacingOccurrences(of: ".\(meeting.audioURL.pathExtension)", with: ".txt"),
            transcriptText: transcriptText,
            audioURL: meeting.audioURL
        )

        let createResponse = try await client.submitMeeting(payload)
        try await store.updateSummarySubmission(
            meetingID: meetingID,
            status: createResponse.status,
            externalMeetingID: createResponse.externalMeetingID,
            jobID: createResponse.jobID,
            taskID: createResponse.taskID,
            pollURL: createResponse.pollURL,
            responseJSON: createResponse.rawResponseJSON
        )

        if pollsInBackground {
            _ = await startBackgroundPoll(meetingID: meetingID, jobID: createResponse.jobID, source: "submit")
        } else {
            try await pollUntilFinished(meetingID: meetingID, jobID: createResponse.jobID)
        }
    }

    func resumeMeeting(meetingID: UUID) async throws {
        guard let meeting = try await store.fetchMeeting(id: meetingID) else {
            throw MeetingSummaryClientError.invalidResponse
        }

        guard meeting.status == .completed else {
            throw MeetingSummaryClientError.requestFailed(statusCode: 0, body: "请先完成文字记录处理。")
        }

        guard !meeting.summaryJobID.isEmpty else {
            throw MeetingSummaryClientError.invalidResponse
        }

        guard [.received, .queued, .processing].contains(meeting.summaryStatus) else {
            return
        }

        if pollsInBackground {
            _ = await startBackgroundPoll(meetingID: meetingID, jobID: meeting.summaryJobID, source: "resume")
        } else {
            MeetingLog.info("Meeting summary resume polling meetingID=\(meetingID) jobID=\(meeting.summaryJobID)")
            try await pollUntilFinished(meetingID: meetingID, jobID: meeting.summaryJobID)
        }
    }

    @discardableResult
    private func startBackgroundPoll(meetingID: UUID, jobID: String, source: String) async -> Bool {
        guard let token = await Self.pollingRegistry.begin(meetingID: meetingID) else {
            MeetingLog.info("Meeting summary poll already active, skip source=\(source) meetingID=\(meetingID) jobID=\(jobID)")
            return false
        }

        MeetingLog.info("Meeting summary poll started source=\(source) meetingID=\(meetingID) jobID=\(jobID)")
        Task(priority: .background) { [client, store, pollInterval, maxPollCount] in
            defer {
                Task {
                    await Self.pollingRegistry.end(meetingID: meetingID, token: token)
                }
            }

            let backgroundService = MeetingSummaryService(
                client: client,
                store: store,
                pollInterval: pollInterval,
                maxPollCount: maxPollCount,
                pollsInBackground: false
            )

            do {
                try await backgroundService.pollUntilFinished(meetingID: meetingID, jobID: jobID)
                MeetingLog.info("Meeting summary poll finished meetingID=\(meetingID) jobID=\(jobID)")
            } catch is CancellationError {
                MeetingLog.info("Meeting summary poll cancelled meetingID=\(meetingID) jobID=\(jobID)")
            } catch {
                MeetingLog.error("Meeting summary background poll failed meetingID=\(meetingID) jobID=\(jobID) error=\(error.localizedDescription)")
            }
        }
        return true
    }

    private func pollUntilFinished(meetingID: UUID, jobID: String) async throws {
        var remainingPolls = maxPollCount

        while remainingPolls > 0 {
            remainingPolls -= 1
            if pollInterval > .zero {
                try await Task.sleep(for: pollInterval)
            }

            let response = try await client.fetchMeeting(jobID: jobID)
            switch response.status {
            case .received, .queued, .processing:
                try await store.updateSummaryStatus(
                    meetingID: meetingID,
                    status: response.status,
                    responseJSON: response.rawResponseJSON
                )
            case .completed:
                MeetingLog.info(
                    "Meeting summary completed jobID=\(jobID) summaryTextLength=\(response.summaryText.count) fullTextLength=\(response.fullText.count)"
                )
                try await store.updateSummaryResult(
                    meetingID: meetingID,
                    summaryText: response.summaryText,
                    fullText: response.fullText,
                    result: response.result ?? .empty(meetingTitle: response.meetingTitle),
                    shareURL: response.shareURL,
                    responseJSON: response.rawResponseJSON
                )
                return
            case .failed:
                let message = response.errorMessage.isEmpty ? "服务端处理失败。" : response.errorMessage
                try await store.updateSummaryStatus(
                    meetingID: meetingID,
                    status: .failed,
                    errorMessage: message,
                    responseJSON: response.rawResponseJSON
                )
                throw MeetingSummaryClientError.requestFailed(statusCode: 0, body: message)
            case .unsubmitted:
                continue
            }
        }

        let message = "服务端总结超时，请稍后重试。"
        try await store.updateSummaryStatus(
            meetingID: meetingID,
            status: .failed,
            errorMessage: message
        )
        throw MeetingSummaryClientError.requestFailed(statusCode: 0, body: message)
    }

    private static func meetingLanguage() -> String {
        let selected = AppPreferences.shared.whisperLanguage
        if selected == "zh" {
            return "zh-CN"
        }
        if selected == "auto" {
            return "zh-CN"
        }
        return selected
    }

    private static func submissionIdentity(for meeting: MeetingRecord) -> (externalMeetingID: String, idempotencyKey: String) {
        if meeting.summaryStatus == .failed {
            let retryToken = String(Int(Date().timeIntervalSince1970))
            return (
                externalMeetingID: "\(meeting.id.uuidString)-retry-\(retryToken)",
                idempotencyKey: "neutype-\(meeting.id.uuidString)-summary-retry-\(retryToken)"
            )
        }

        let externalMeetingID = meeting.summaryExternalMeetingID.isEmpty
            ? meeting.id.uuidString
            : meeting.summaryExternalMeetingID
        return (
            externalMeetingID: externalMeetingID,
            idempotencyKey: "neutype-\(meeting.id.uuidString)-summary"
        )
    }
}

private extension MeetingSummaryResult {
    static func empty(meetingTitle: String) -> MeetingSummaryResult {
        MeetingSummaryResult(
            meetingTitle: meetingTitle,
            meetingStartedAt: nil,
            meetingEndedAt: nil,
            summary: "",
            keyPoints: [],
            actionItems: [],
            risks: [],
            shareSummary: ""
        )
    }
}
