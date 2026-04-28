import Foundation
import GRDB

enum MeetingTranscriptLanguage: String, CaseIterable, Identifiable, Equatable, Sendable {
    case original
    case english
    case chinese
    case arabic

    var id: Self { self }

    var title: String {
        switch self {
        case .original:
            return "原始"
        case .english:
            return "英文"
        case .chinese:
            return "中文"
        case .arabic:
            return "阿语"
        }
    }
}

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

    func displayText(for language: MeetingTranscriptLanguage) -> String {
        switch language {
        case .original:
            return text
        case .english:
            return nonEmptyTranslation(textEN) ?? text
        case .chinese:
            return nonEmptyTranslation(textZH) ?? text
        case .arabic:
            return nonEmptyTranslation(textAR) ?? text
        }
    }

    var hasCompleteTranslations: Bool {
        nonEmptyTranslation(textEN) != nil
            && nonEmptyTranslation(textZH) != nil
            && nonEmptyTranslation(textAR) != nil
    }

    private func nonEmptyTranslation(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
