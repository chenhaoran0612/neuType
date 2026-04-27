import Foundation
import GRDB

struct MeetingTranscriptSegment: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    let sequence: Int
    let speakerLabel: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let textEN: String
    let textZH: String
    let textAR: String

    init(
        id: UUID,
        meetingID: UUID,
        sequence: Int,
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        textEN: String = "",
        textZH: String = "",
        textAR: String = ""
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sequence = sequence
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.textEN = textEN
        self.textZH = textZH
        self.textAR = textAR
    }

    static let databaseTableName = "meeting_transcript_segments"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let meetingID = Column(CodingKeys.meetingID)
        static let sequence = Column(CodingKeys.sequence)
        static let speakerLabel = Column(CodingKeys.speakerLabel)
        static let startTime = Column(CodingKeys.startTime)
        static let endTime = Column(CodingKeys.endTime)
        static let text = Column(CodingKeys.text)
        static let textEN = Column(CodingKeys.textEN)
        static let textZH = Column(CodingKeys.textZH)
        static let textAR = Column(CodingKeys.textAR)
    }
}
