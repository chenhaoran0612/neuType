import Foundation
import GRDB

struct MeetingTranscriptSegment: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let meetingID: UUID
    let sequence: Int
    let speakerLabel: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    static let databaseTableName = "meeting_transcript_segments"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let meetingID = Column(CodingKeys.meetingID)
        static let sequence = Column(CodingKeys.sequence)
        static let speakerLabel = Column(CodingKeys.speakerLabel)
        static let startTime = Column(CodingKeys.startTime)
        static let endTime = Column(CodingKeys.endTime)
        static let text = Column(CodingKeys.text)
    }
}
