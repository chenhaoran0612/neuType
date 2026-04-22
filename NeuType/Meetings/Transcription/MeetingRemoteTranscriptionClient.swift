import Foundation

enum MeetingRemoteTranscriptionClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case invalidResponse
    case missingResponseData(requestID: String)
    case apiError(statusCode: Int, requestID: String, code: String, message: String)
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            "Invalid meeting transcription API base URL: \(value)"
        case .invalidResponse:
            "Meeting transcription service returned an invalid response"
        case .missingResponseData:
            "Meeting transcription service returned an empty response"
        case .apiError(let statusCode, _, let code, let message):
            "Meeting transcription request failed (\(statusCode), \(code)): \(message)"
        case .requestFailed(let statusCode, let body):
            "Meeting transcription request failed (\(statusCode)): \(body)"
        }
    }
}

final class MeetingRemoteTranscriptionClient: Sendable {
    private enum Timeout {
        static let request: TimeInterval = 120
    }

    private let session: URLSession
    private let configProvider: MeetingVibeVoiceConfigProviding

    init(
        session: URLSession = .shared,
        configProvider: MeetingVibeVoiceConfigProviding = AppPreferences.shared
    ) {
        self.session = session
        self.configProvider = configProvider
    }

    func createSession(
        _ requestPayload: CreateMeetingTranscriptionSessionRequest
    ) async throws -> CreateMeetingTranscriptionSessionResponse {
        let config = configProvider.meetingVibeVoiceConfig
        guard let url = config.remoteMeetingTranscriptionSessionsURL() else {
            throw MeetingRemoteTranscriptionClientError.invalidBaseURL(config.baseURL)
        }

        let request = try makeJSONRequest(url: url, method: "POST", config: config, payload: requestPayload)
        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(
            CreateMeetingTranscriptionSessionResponse.self,
            data: data,
            response: response
        )
    }

    func uploadChunk(
        _ requestPayload: MeetingRemoteTranscriptionChunkUploadRequest
    ) async throws -> MeetingRemoteTranscriptionChunkUploadResponse {
        let config = configProvider.meetingVibeVoiceConfig
        guard let url = config.remoteMeetingTranscriptionChunkUploadURL(
            sessionID: requestPayload.sessionID,
            chunkIndex: requestPayload.chunkIndex
        ) else {
            throw MeetingRemoteTranscriptionClientError.invalidBaseURL(config.baseURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = makeRequest(url: url, method: "PUT", config: config)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeMultipartBody(payload: requestPayload, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(
            MeetingRemoteTranscriptionChunkUploadResponse.self,
            data: data,
            response: response
        )
    }

    func finalizeSession(
        sessionID: String,
        request requestPayload: FinalizeMeetingTranscriptionSessionRequest
    ) async throws -> FinalizeMeetingTranscriptionSessionResponse {
        let config = configProvider.meetingVibeVoiceConfig
        guard let url = config.remoteMeetingTranscriptionFinalizeURL(sessionID: sessionID) else {
            throw MeetingRemoteTranscriptionClientError.invalidBaseURL(config.baseURL)
        }

        let request = try makeJSONRequest(url: url, method: "POST", config: config, payload: requestPayload)
        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(
            FinalizeMeetingTranscriptionSessionResponse.self,
            data: data,
            response: response
        )
    }

    func uploadFullAudio(
        _ requestPayload: MeetingRemoteTranscriptionFullAudioUploadRequest
    ) async throws -> MeetingRemoteTranscriptionFullAudioUploadResponse {
        let config = configProvider.meetingVibeVoiceConfig
        guard let url = config.remoteMeetingTranscriptionFullAudioUploadURL(
            sessionID: requestPayload.sessionID
        ) else {
            throw MeetingRemoteTranscriptionClientError.invalidBaseURL(config.baseURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = makeRequest(url: url, method: "PUT", config: config)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeMultipartBody(payload: requestPayload, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(
            MeetingRemoteTranscriptionFullAudioUploadResponse.self,
            data: data,
            response: response
        )
    }

    func getSessionStatus(sessionID: String) async throws -> MeetingRemoteTranscriptionSessionStatusResponse {
        let config = configProvider.meetingVibeVoiceConfig
        guard let url = config.remoteMeetingTranscriptionSessionURL(sessionID: sessionID) else {
            throw MeetingRemoteTranscriptionClientError.invalidBaseURL(config.baseURL)
        }

        let request = makeRequest(url: url, method: "GET", config: config)
        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(
            MeetingRemoteTranscriptionSessionStatusResponse.self,
            data: data,
            response: response
        )
    }

    private func makeJSONRequest<Payload: Encodable>(
        url: URL,
        method: String,
        config: MeetingVibeVoiceConfig,
        payload: Payload
    ) throws -> URLRequest {
        var request = makeRequest(url: url, method: method, config: config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func makeRequest(url: URL, method: String, config: MeetingVibeVoiceConfig) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Timeout.request

        let apiKey = config.trimmedAPIKey
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        return request
    }

    private func decodeEnvelope<Payload: Decodable & Sendable>(
        _ payloadType: Payload.Type,
        data: Data,
        response: URLResponse
    ) throws -> Payload {
        let httpResponse = try httpResponse(from: response)

        if !(200..<300).contains(httpResponse.statusCode) {
            if let envelope = try? JSONDecoder().decode(MeetingRemoteTranscriptionEnvelope<Payload>.self, from: data),
               let apiError = envelope.error {
                throw MeetingRemoteTranscriptionClientError.apiError(
                    statusCode: httpResponse.statusCode,
                    requestID: envelope.requestID,
                    code: apiError.code,
                    message: apiError.message
                )
            }

            let body = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw MeetingRemoteTranscriptionClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                body: body
            )
        }

        let envelope = try JSONDecoder().decode(MeetingRemoteTranscriptionEnvelope<Payload>.self, from: data)
        if let apiError = envelope.error {
            throw MeetingRemoteTranscriptionClientError.apiError(
                statusCode: httpResponse.statusCode,
                requestID: envelope.requestID,
                code: apiError.code,
                message: apiError.message
            )
        }

        guard let payload = envelope.data else {
            throw MeetingRemoteTranscriptionClientError.missingResponseData(requestID: envelope.requestID)
        }

        return payload
    }

    private func httpResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingRemoteTranscriptionClientError.invalidResponse
        }
        return httpResponse
    }

    private static func makeMultipartBody(
        payload: MeetingRemoteTranscriptionChunkUploadRequest,
        boundary: String
    ) -> Data {
        var body = Data()
        appendField("start_ms", value: String(payload.startMS), to: &body, boundary: boundary)
        appendField("end_ms", value: String(payload.endMS), to: &body, boundary: boundary)
        appendField("sha256", value: payload.sha256, to: &body, boundary: boundary)
        appendField("mime_type", value: payload.mimeType, to: &body, boundary: boundary)
        appendField("file_size_bytes", value: String(payload.fileSizeBytes), to: &body, boundary: boundary)
        appendFile(
            name: "audio_file",
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            fileData: payload.audioData,
            to: &body,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n")
        return body
    }

    private static func makeMultipartBody(
        payload: MeetingRemoteTranscriptionFullAudioUploadRequest,
        boundary: String
    ) -> Data {
        var body = Data()
        appendField("sha256", value: payload.sha256, to: &body, boundary: boundary)
        appendField("duration_ms", value: String(payload.durationMS), to: &body, boundary: boundary)
        appendField("mime_type", value: payload.mimeType, to: &body, boundary: boundary)
        appendField("file_size_bytes", value: String(payload.fileSizeBytes), to: &body, boundary: boundary)
        appendFile(
            name: "audio_file",
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            fileData: payload.audioData,
            to: &body,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n")
        return body
    }

    private static func appendField(_ name: String, value: String, to body: inout Data, boundary: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    private static func appendFile(
        name: String,
        fileName: String,
        mimeType: String,
        fileData: Data,
        to body: inout Data,
        boundary: String
    ) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
