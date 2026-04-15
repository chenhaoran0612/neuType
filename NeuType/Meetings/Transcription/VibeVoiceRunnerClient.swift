import Foundation

enum VibeVoiceRunnerError: LocalizedError {
    case invalidBaseURL(String)
    case invalidUploadResponse
    case invalidEventResponse
    case invalidEventStream
    case invalidRawTextPayload
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            "Invalid VibeVoice API base URL: \(value)"
        case .invalidUploadResponse:
            "VibeVoice upload response was invalid"
        case .invalidEventResponse:
            "VibeVoice event response was invalid"
        case .invalidEventStream:
            "VibeVoice event stream did not contain a completed result"
        case .invalidRawTextPayload:
            "VibeVoice raw_text payload could not be parsed"
        case .processFailed(let message):
            message
        }
    }
}

protocol VibeVoiceRunning {
    func transcribe(audioURL: URL, hotwords: [String]) async throws -> MeetingTranscriptionResult
}

final class VibeVoiceRunnerClient: VibeVoiceRunning {
    private enum Timeout {
        static let upload: TimeInterval = 1800
        static let config: TimeInterval = 60
        static let queueJoin: TimeInterval = 1800
        static let queueData: TimeInterval = 3600
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let configProvider: MeetingVibeVoiceConfigProviding

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        configProvider: MeetingVibeVoiceConfigProviding = AppPreferences.shared
    ) {
        self.session = session
        self.decoder = decoder
        self.configProvider = configProvider
    }

    func transcribe(audioURL: URL, hotwords: [String] = []) async throws -> MeetingTranscriptionResult {
        let config = configProvider.meetingVibeVoiceConfig
        MeetingLog.info("VibeVoice transcription start file=\(audioURL.lastPathComponent)")
        let uploadedPath = try await uploadAudio(audioURL: audioURL, config: config)
        let functionIndex = try await fetchTranscribeFunctionIndex(config: config)
        let sessionHash = UUID().uuidString
        let eventID = try await submitQueuedTranscription(
            uploadedPath: uploadedPath,
            originalFileName: audioURL.lastPathComponent,
            contextInfo: config.combinedContextInfo(hotwords: hotwords),
            functionIndex: functionIndex,
            sessionHash: sessionHash,
            config: config
        )
        let rawText = try await readQueuedRawText(eventID: eventID, sessionHash: sessionHash, config: config)
        let result = try Self.decodeResult(from: Data(rawText.utf8), decoder: decoder)
        MeetingLog.info("VibeVoice transcription completed eventID=\(eventID) segments=\(result.segments.count)")
        return result
    }

    private func uploadAudio(audioURL: URL, config: MeetingVibeVoiceConfig) async throws -> String {
        guard let uploadURL = config.endpointURL(path: "upload") else {
            throw VibeVoiceRunnerError.invalidBaseURL(config.baseURL)
        }
        MeetingLog.info("VibeVoice upload request url=\(uploadURL.absoluteString)")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Timeout.upload
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeMultipartBody(audioURL: audioURL, boundary: boundary)

        RequestLogStore.log(.asr, "Meeting ASR upload -> \(uploadURL.absoluteString)")
        let (data, response) = try await session.data(for: request)
        try Self.ensureSuccess(response)

        guard
            let paths = try JSONSerialization.jsonObject(with: data) as? [String],
            let uploadedPath = paths.first
        else {
            MeetingLog.error("VibeVoice upload invalid response body=\(String(decoding: data, as: UTF8.self))")
            throw VibeVoiceRunnerError.invalidUploadResponse
        }

        MeetingLog.info("VibeVoice upload succeeded path=\(uploadedPath)")
        return uploadedPath
    }

    private func fetchTranscribeFunctionIndex(config: MeetingVibeVoiceConfig) async throws -> Int {
        guard let configURL = URL(string: config.baseURL)?.appending(path: "config") else {
            throw VibeVoiceRunnerError.invalidBaseURL(config.baseURL)
        }
        MeetingLog.info("VibeVoice config request url=\(configURL.absoluteString)")

        var request = URLRequest(url: configURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Timeout.config

        RequestLogStore.log(.asr, "Meeting ASR config -> \(configURL.absoluteString)")
        let (data, response) = try await session.data(for: request)
        try Self.ensureSuccess(response)

        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dependencies = payload["dependencies"] as? [[String: Any]],
            let entry = dependencies.first(where: { ($0["api_name"] as? String) == "transcribe_audio" }),
            let functionIndex = entry["id"] as? Int
        else {
            MeetingLog.error("VibeVoice config missing transcribe_audio dependency")
            throw VibeVoiceRunnerError.processFailed("VibeVoice config did not expose transcribe_audio")
        }

        MeetingLog.info("VibeVoice resolved fn_index=\(functionIndex)")
        return functionIndex
    }

    private func submitQueuedTranscription(
        uploadedPath: String,
        originalFileName: String,
        contextInfo: String,
        functionIndex: Int,
        sessionHash: String,
        config: MeetingVibeVoiceConfig
    ) async throws -> String {
        guard let submitURL = config.endpointURL(path: "queue/join") else {
            throw VibeVoiceRunnerError.invalidBaseURL(config.baseURL)
        }
        MeetingLog.info("VibeVoice queue join request url=\(submitURL.absoluteString)")

        var request = URLRequest(url: submitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Timeout.queueJoin
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GradioQueueRequest(
                data: [
                    .file(GradioFileData(path: uploadedPath, origName: originalFileName)),
                    .string(""),
                    .string(""),
                    .string(""),
                    .int(config.maxNewTokens),
                    .double(config.temperature),
                    .double(config.topP),
                    .bool(config.doSample),
                    .double(config.repetitionPenalty),
                    .string(contextInfo),
                ],
                functionIndex: functionIndex,
                sessionHash: sessionHash
            )
        )

        RequestLogStore.log(.asr, "Meeting ASR queue join -> \(submitURL.absoluteString)")
        let (data, response) = try await session.data(for: request)
        try Self.ensureSuccess(response)

        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventID = payload["event_id"] as? String,
            !eventID.isEmpty
        else {
            MeetingLog.error("VibeVoice queue join invalid response body=\(String(decoding: data, as: UTF8.self))")
            throw VibeVoiceRunnerError.invalidEventResponse
        }

        MeetingLog.info("VibeVoice queue join succeeded eventID=\(eventID)")
        return eventID
    }

    private func readQueuedRawText(
        eventID: String,
        sessionHash: String,
        config: MeetingVibeVoiceConfig
    ) async throws -> String {
        guard let eventsURL = config.endpointURL(path: "queue/data") else {
            throw VibeVoiceRunnerError.invalidBaseURL(config.baseURL)
        }

        var components = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "session_hash", value: sessionHash)]
        guard let url = components?.url else {
            throw VibeVoiceRunnerError.invalidBaseURL(config.baseURL)
        }
        MeetingLog.info("VibeVoice queue data request url=\(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Timeout.queueData

        RequestLogStore.log(.asr, "Meeting ASR queue data -> \(url.absoluteString)")
        let (data, response) = try await session.data(for: request)
        try Self.ensureSuccess(response)

        guard let rawText = Self.extractQueuedRawText(from: data, eventID: eventID) else {
            MeetingLog.error("VibeVoice queue stream missing completed result eventID=\(eventID) body=\(String(decoding: data, as: UTF8.self).prefix(2000))")
            throw VibeVoiceRunnerError.invalidEventStream
        }

        return rawText
    }

    private static func makeMultipartBody(audioURL: URL, boundary: String) throws -> Data {
        let fileData = try Data(contentsOf: audioURL)
        var body = Data()
        let mimeType = mimeType(for: audioURL.pathExtension)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"files\"; filename=\"\(audioURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        default: "application/octet-stream"
        }
    }

    private static func ensureSuccess(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VibeVoiceRunnerError.processFailed("VibeVoice request returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VibeVoiceRunnerError.processFailed("VibeVoice request failed with status \(httpResponse.statusCode)")
        }
    }

    static func extractQueuedRawText(from data: Data, eventID: String) -> String? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }

        let chunks = body.components(separatedBy: "\n\n")
        for chunk in chunks.reversed() {
            guard let dataLine = chunk.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) else {
                continue
            }

            let payloadString = String(dataLine.dropFirst(6))
            guard
                let payloadData = payloadString.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                payload["event_id"] as? String == eventID,
                payload["success"] as? Bool != false
            else {
                continue
            }

            guard let output = payload["output"] as? [String: Any] else {
                continue
            }

            let message = payload["msg"] as? String
            let isGenerating = output["is_generating"] as? Bool
            let isTerminalEvent = message == "process_completed" || (message == "process_generating" && isGenerating == false)
            guard isTerminalEvent, let values = output["data"] as? [Any] else {
                continue
            }

            if let rawText = extractRawText(from: values.first) {
                return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private static func extractRawText(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let patches as [Any]:
            let candidates = patches.compactMap { extractRawText(from: $0) }
            return candidates.first(where: { $0.contains("assistant") }) ?? candidates.first
        default:
            return nil
        }
    }

    static func decodeResult(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> MeetingTranscriptionResult {
        guard let payload = String(data: data, encoding: .utf8) else {
            throw VibeVoiceRunnerError.invalidRawTextPayload
        }

        let jsonString: String
        do {
            jsonString = try extractAssistantJSON(from: payload)
        } catch {
            if let serviceMessage = extractServiceError(from: payload) {
                throw VibeVoiceRunnerError.processFailed(serviceMessage)
            }
            throw error
        }
        let jsonData = Data(jsonString.utf8)
        let segments: [VibeVoiceSegment]
        do {
            segments = try decoder.decode([VibeVoiceSegment].self, from: jsonData)
        } catch {
            if let serviceMessage = extractServiceError(from: payload) {
                throw VibeVoiceRunnerError.processFailed(serviceMessage)
            }
            throw error
        }
        let normalizedSegments = segments.enumerated().map { index, segment in
            MeetingTranscriptionSegmentPayload(
                sequence: index,
                speakerLabel: segment.speakerLabel,
                startTime: segment.start,
                endTime: segment.end,
                text: segment.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let fullText = normalizedSegments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return MeetingTranscriptionResult(fullText: fullText, segments: normalizedSegments)
    }

    private static func extractAssistantJSON(from payload: String) throws -> String {
        let assistantRange = payload.range(of: "assistant")
        let searchStart = assistantRange?.upperBound ?? payload.startIndex
        let searchSlice = payload[searchStart...]

        if let arrayIndex = searchSlice.firstIndex(of: "[") {
            return try extractBalancedJSON(in: searchSlice, startingAt: arrayIndex, open: "[", close: "]")
        }
        if let objectIndex = searchSlice.firstIndex(of: "{") {
            return try extractBalancedJSON(in: searchSlice, startingAt: objectIndex, open: "{", close: "}")
        }

        throw VibeVoiceRunnerError.invalidRawTextPayload
    }

    private static func extractBalancedJSON(
        in payload: Substring,
        startingAt startIndex: Substring.Index,
        open: Character,
        close: Character
    ) throws -> String {
        var depth = 0
        var isEscaping = false
        var isInsideString = false
        var currentIndex = startIndex

        while currentIndex < payload.endIndex {
            let character = payload[currentIndex]

            if isEscaping {
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if character == "\"" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == open {
                    depth += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 {
                        let endIndex = payload.index(after: currentIndex)
                        return String(payload[startIndex..<endIndex])
                    }
                }
            }

            currentIndex = payload.index(after: currentIndex)
        }

        throw VibeVoiceRunnerError.invalidRawTextPayload
    }

    private static func extractServiceError(from payload: String) -> String? {
        let normalizedPayload = payload.replacingOccurrences(of: "\\u274c", with: "❌")

        if normalizedPayload.contains("No audio segments available.") {
            return "No audio segments available. This could happen if the model output doesn't contain valid time stamps."
        }

        if let range = normalizedPayload.range(of: "<p>❌ "),
           let closingRange = normalizedPayload[range.upperBound...].range(of: "</p>") {
            return String(normalizedPayload[range.upperBound..<closingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

private struct GradioQueueRequest: Encodable {
    let data: [GradioValue]
    let functionIndex: Int
    let sessionHash: String

    enum CodingKeys: String, CodingKey {
        case data
        case functionIndex = "fn_index"
        case sessionHash = "session_hash"
    }
}

private enum GradioValue: Encodable {
    case file(GradioFileData)
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .file(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

private struct GradioFileData: Encodable {
    let path: String
    let origName: String
    let meta = GradioFileMeta()

    enum CodingKeys: String, CodingKey {
        case path
        case origName = "orig_name"
        case meta
    }
}

private struct GradioFileMeta: Encodable {
    let type = "gradio.FileData"

    enum CodingKeys: String, CodingKey {
        case type = "_type"
    }
}

private struct VibeVoiceSegment: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int?
    let content: String

    enum CodingKeys: String, CodingKey {
        case start = "Start"
        case end = "End"
        case speaker = "Speaker"
        case content = "Content"
    }

    var speakerLabel: String {
        guard let speaker else { return "Unknown" }
        return "Speaker \(speaker + 1)"
    }
}
