import Foundation

struct MeetingTranscriptionResult: Decodable, Equatable, Sendable {
    let fullText: String
    let segments: [MeetingTranscriptionSegmentPayload]

    enum CodingKeys: String, CodingKey {
        case fullText = "full_text"
        case segments
    }
}

struct MeetingTranscriptionSegmentPayload: Decodable, Equatable, Sendable {
    let sequence: Int
    let speakerLabel: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let textEN: String
    let textZH: String
    let textAR: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case speakerLabel = "speaker_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case text
        case textEN = "text_en"
        case textZH = "text_zh"
        case textAR = "text_ar"
    }

    init(
        sequence: Int,
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        textEN: String = "",
        textZH: String = "",
        textAR: String = ""
    ) {
        self.sequence = sequence
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.textEN = textEN
        self.textZH = textZH
        self.textAR = textAR
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        speakerLabel = try container.decode(String.self, forKey: .speakerLabel)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        text = try container.decode(String.self, forKey: .text)
        textEN = try container.decodeIfPresent(String.self, forKey: .textEN) ?? ""
        textZH = try container.decodeIfPresent(String.self, forKey: .textZH) ?? ""
        textAR = try container.decodeIfPresent(String.self, forKey: .textAR) ?? ""
    }
}
