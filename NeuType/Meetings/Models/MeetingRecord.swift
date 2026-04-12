import Foundation
import GRDB

enum MeetingRecordStatus: String, Codable {
    case recording
    case processing
    case completed
    case failed
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
}
