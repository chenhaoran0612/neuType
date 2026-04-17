import Foundation
import GRDB

enum MeetingRecordStatus: String, Codable {
    case recording
    case unprocessed
    case processing
    case completed
    case failed
}

enum MeetingSummaryStatus: String, Codable {
    case unsubmitted
    case received
    case queued
    case processing
    case completed
    case failed
}

struct MeetingSummaryActionItem: Codable, Equatable {
    let owner: String
    let task: String
    let dueAt: String?

    enum CodingKeys: String, CodingKey {
        case owner
        case task
        case dueAt = "due_at"
    }
}

struct MeetingSummaryResult: Codable, Equatable {
    let meetingTitle: String
    let meetingStartedAt: Date?
    let meetingEndedAt: Date?
    let summary: String
    let keyPoints: [String]
    let actionItems: [MeetingSummaryActionItem]
    let risks: [String]
    let shareSummary: String

    enum CodingKeys: String, CodingKey {
        case meetingTitle = "meeting_title"
        case meetingStartedAt = "meeting_started_at"
        case meetingEndedAt = "meeting_ended_at"
        case summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case risks
        case shareSummary = "share_summary"
    }
}

struct MeetingRecord: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let createdAt: Date
    var title: String
    let audioFileName: String
    var transcriptPreview: String
    let duration: TimeInterval
    var status: MeetingRecordStatus
    var progress: Float
    var summaryStatus: MeetingSummaryStatus = .unsubmitted
    var summaryExternalMeetingID: String = ""
    var summaryJobID: String = ""
    var summaryTaskID: String = ""
    var summaryPollURL: String = ""
    var summaryText: String = ""
    var summaryFullText: String = ""
    var summaryResultJSON: String = ""
    var summaryLastResponseJSON: String = ""
    var summaryShareURL: String = ""
    var summaryErrorMessage: String = ""

    static let databaseTableName = "meeting_records"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
        static let title = Column(CodingKeys.title)
        static let audioFileName = Column(CodingKeys.audioFileName)
        static let transcriptPreview = Column(CodingKeys.transcriptPreview)
        static let duration = Column(CodingKeys.duration)
        static let status = Column(CodingKeys.status)
        static let progress = Column(CodingKeys.progress)
        static let summaryStatus = Column(CodingKeys.summaryStatus)
        static let summaryExternalMeetingID = Column(CodingKeys.summaryExternalMeetingID)
        static let summaryJobID = Column(CodingKeys.summaryJobID)
        static let summaryTaskID = Column(CodingKeys.summaryTaskID)
        static let summaryPollURL = Column(CodingKeys.summaryPollURL)
        static let summaryText = Column(CodingKeys.summaryText)
        static let summaryFullText = Column(CodingKeys.summaryFullText)
        static let summaryResultJSON = Column(CodingKeys.summaryResultJSON)
        static let summaryLastResponseJSON = Column(CodingKeys.summaryLastResponseJSON)
        static let summaryShareURL = Column(CodingKeys.summaryShareURL)
        static let summaryErrorMessage = Column(CodingKeys.summaryErrorMessage)
    }

    static var meetingsDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "NeuType"
        return applicationSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent("meetings")
    }

    var audioURL: URL {
        Self.meetingsDirectory.appendingPathComponent(audioFileName)
    }

    var decodedSummaryResult: MeetingSummaryResult? {
        guard !summaryResultJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = summaryResultJSON.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSummaryResult.self, from: data)
    }
}
