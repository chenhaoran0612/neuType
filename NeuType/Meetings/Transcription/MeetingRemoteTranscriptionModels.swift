import Foundation

struct MeetingRemoteTranscriptionAPIErrorPayload: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct MeetingRemoteTranscriptionEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let requestID: String
    let data: Payload?
    let error: MeetingRemoteTranscriptionAPIErrorPayload?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case data
        case error
    }
}

struct CreateMeetingTranscriptionSessionRequest: Codable, Equatable, Sendable {
    let clientSessionToken: String
    let source: String
    let chunkDurationMS: Int
    let chunkOverlapMS: Int
    let audioFormat: String
    let sampleRateHZ: Int
    let channelCount: Int

    enum CodingKeys: String, CodingKey {
        case clientSessionToken = "client_session_token"
        case source
        case chunkDurationMS = "chunk_duration_ms"
        case chunkOverlapMS = "chunk_overlap_ms"
        case audioFormat = "audio_format"
        case sampleRateHZ = "sample_rate_hz"
        case channelCount = "channel_count"
    }
}

struct CreateMeetingTranscriptionSessionResponse: Codable, Equatable, Sendable {
    let sessionID: String
    let status: String
    let inputMode: String
    let chunkDurationMS: Int
    let chunkOverlapMS: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case inputMode = "input_mode"
        case chunkDurationMS = "chunk_duration_ms"
        case chunkOverlapMS = "chunk_overlap_ms"
    }
}

struct MeetingRemoteTranscriptionChunkUploadRequest: Codable, Equatable, Sendable {
    let sessionID: String
    let chunkIndex: Int
    let audioData: Data
    let fileName: String
    let startMS: Int
    let endMS: Int
    let sha256: String
    let mimeType: String
    let fileSizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case chunkIndex = "chunk_index"
        case audioData = "audio_data"
        case fileName = "file_name"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case sha256
        case mimeType = "mime_type"
        case fileSizeBytes = "file_size_bytes"
    }
}

struct MeetingRemoteTranscriptionChunkUploadResponse: Codable, Equatable, Sendable {
    let sessionID: String
    let chunkIndex: Int
    let status: String
    let uploadStatus: String
    let processStatus: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case chunkIndex = "chunk_index"
        case status
        case uploadStatus = "upload_status"
        case processStatus = "process_status"
    }
}

struct FinalizeMeetingTranscriptionSessionRequest: Codable, Equatable, Sendable {
    let expectedChunkCount: Int?
    let preferredInputMode: String
    let allowFullAudioFallback: Bool
    let recordingEndedAtMS: Int?

    enum CodingKeys: String, CodingKey {
        case expectedChunkCount = "expected_chunk_count"
        case preferredInputMode = "preferred_input_mode"
        case allowFullAudioFallback = "allow_full_audio_fallback"
        case recordingEndedAtMS = "recording_ended_at_ms"
    }
}

struct FinalizeMeetingTranscriptionSessionResponse: Codable, Equatable, Sendable {
    let sessionID: String
    let status: String
    let selectedInputMode: String
    let missingChunkIndexes: [Int]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case selectedInputMode = "selected_input_mode"
        case missingChunkIndexes = "missing_chunk_indexes"
    }
}

struct MeetingRemoteTranscriptionSessionStatusResponse: Codable, Equatable, Sendable {
    let sessionID: String
    let status: String
    let inputMode: String
    let chunkDurationMS: Int?
    let chunkOverlapMS: Int?
    let expectedChunkCount: Int?
    let uploadedChunkCount: Int?
    let fullText: String?
    let segments: [RemoteMeetingTranscriptSegment]?

    var transcriptResult: RemoteMeetingTranscriptResult? {
        guard let fullText, let segments else { return nil }
        return RemoteMeetingTranscriptResult(fullText: fullText, segments: segments)
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case inputMode = "input_mode"
        case chunkDurationMS = "chunk_duration_ms"
        case chunkOverlapMS = "chunk_overlap_ms"
        case expectedChunkCount = "expected_chunk_count"
        case uploadedChunkCount = "uploaded_chunk_count"
        case fullText = "full_text"
        case segments
    }
}

struct RemoteMeetingTranscriptResult: Codable, Equatable, Sendable {
    let fullText: String
    let segments: [RemoteMeetingTranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case fullText = "full_text"
        case segments
    }
}

struct RemoteMeetingTranscriptSegment: Codable, Equatable, Sendable {
    let sequence: Int
    let speakerLabel: String?
    let startMS: Int
    let endMS: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case speakerLabel = "speaker_label"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case text
    }
}

struct MeetingRemoteTranscriptionFullAudioUploadRequest: Codable, Equatable, Sendable {
    let sessionID: String
    let audioData: Data
    let fileName: String
    let sha256: String
    let durationMS: Int
    let mimeType: String
    let fileSizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case audioData = "audio_data"
        case fileName = "file_name"
        case sha256
        case durationMS = "duration_ms"
        case mimeType = "mime_type"
        case fileSizeBytes = "file_size_bytes"
    }
}

struct MeetingRemoteTranscriptionFullAudioUploadResponse: Codable, Equatable, Sendable {
    let sessionID: String
    let status: String
    let inputMode: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case inputMode = "input_mode"
    }
}
