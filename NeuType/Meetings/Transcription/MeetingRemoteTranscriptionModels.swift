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
    let errorMessage: String?
    let fullText: String?
    let segments: [RemoteMeetingTranscriptSegment]?
    let chunks: [MeetingRemoteTranscriptionChunkStatus]

    init(
        sessionID: String,
        status: String,
        inputMode: String,
        chunkDurationMS: Int?,
        chunkOverlapMS: Int?,
        expectedChunkCount: Int?,
        uploadedChunkCount: Int?,
        errorMessage: String?,
        fullText: String?,
        segments: [RemoteMeetingTranscriptSegment]?,
        chunks: [MeetingRemoteTranscriptionChunkStatus] = []
    ) {
        self.sessionID = sessionID
        self.status = status
        self.inputMode = inputMode
        self.chunkDurationMS = chunkDurationMS
        self.chunkOverlapMS = chunkOverlapMS
        self.expectedChunkCount = expectedChunkCount
        self.uploadedChunkCount = uploadedChunkCount
        self.errorMessage = errorMessage
        self.fullText = fullText
        self.segments = segments
        self.chunks = chunks
    }

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
        case errorMessage = "error_message"
        case fullText = "full_text"
        case segments
        case chunks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        status = try container.decode(String.self, forKey: .status)
        inputMode = try container.decode(String.self, forKey: .inputMode)
        chunkDurationMS = try container.decodeIfPresent(Int.self, forKey: .chunkDurationMS)
        chunkOverlapMS = try container.decodeIfPresent(Int.self, forKey: .chunkOverlapMS)
        expectedChunkCount = try container.decodeIfPresent(Int.self, forKey: .expectedChunkCount)
        uploadedChunkCount = try container.decodeIfPresent(Int.self, forKey: .uploadedChunkCount)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        fullText = try container.decodeIfPresent(String.self, forKey: .fullText)
        segments = try container.decodeIfPresent([RemoteMeetingTranscriptSegment].self, forKey: .segments)
        chunks = try container.decodeIfPresent([MeetingRemoteTranscriptionChunkStatus].self, forKey: .chunks) ?? []
    }
}

struct MeetingRemoteTranscriptionChunkStatus: Codable, Equatable, Sendable {
    let chunkIndex: Int
    let sourceType: String
    let startMS: Int
    let endMS: Int
    let uploadStatus: String
    let processStatus: String
    let retryCount: Int
    let resultSegmentCount: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case chunkIndex = "chunk_index"
        case sourceType = "source_type"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case uploadStatus = "upload_status"
        case processStatus = "process_status"
        case retryCount = "retry_count"
        case resultSegmentCount = "result_segment_count"
        case errorMessage = "error_message"
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
    let translations: RemoteMeetingTranscriptSegmentTranslations?

    enum CodingKeys: String, CodingKey {
        case sequence
        case speakerLabel = "speaker_label"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case text
        case translations
    }

    init(
        sequence: Int,
        speakerLabel: String?,
        startMS: Int,
        endMS: Int,
        text: String,
        translations: RemoteMeetingTranscriptSegmentTranslations? = nil
    ) {
        self.sequence = sequence
        self.speakerLabel = speakerLabel
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.translations = translations
    }
}

struct RemoteMeetingTranscriptSegmentTranslations: Codable, Equatable, Sendable {
    let en: String?
    let zh: String?
    let ar: String?
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
