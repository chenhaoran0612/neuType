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

    enum CodingKeys: String, CodingKey {
        case sequence
        case speakerLabel = "speaker_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case text
    }
}
