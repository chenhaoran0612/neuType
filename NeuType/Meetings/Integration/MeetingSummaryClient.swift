import Foundation

enum MeetingSummaryClientError: LocalizedError {
    case missingConfiguration
    case invalidBaseURL(String)
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "请先在设置中配置 ai-worker 服务地址和 API Key。"
        case .invalidBaseURL(let value):
            return "无效的 ai-worker 服务地址：\(value)"
        case .invalidResponse:
            return "ai-worker 返回了无法解析的响应。"
        case .requestFailed(let statusCode, let body):
            return "ai-worker 请求失败（\(statusCode)）：\(body)"
        }
    }
}

struct MeetingSummarySubmissionPayload: Equatable {
    let externalMeetingID: String
    let idempotencyKey: String
    let meetingTitle: String
    let meetingStartedAt: Date
    let meetingEndedAt: Date
    let meetingTimeZone: String
    let language: String
    let transcriptFileName: String
    let transcriptText: String
    let audioURL: URL
}

struct MeetingSummaryCreateResponse: Decodable, Equatable {
    let jobID: String
    let taskID: String
    let status: MeetingSummaryStatus
    let pollURL: String
    let externalMeetingID: String
    let rawResponseJSON: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case taskID = "task_id"
        case status
        case pollURL = "poll_url"
        case externalMeetingID = "external_meeting_id"
    }

    init(
        jobID: String,
        taskID: String,
        status: MeetingSummaryStatus,
        pollURL: String,
        externalMeetingID: String,
        rawResponseJSON: String = ""
    ) {
        self.jobID = jobID
        self.taskID = taskID
        self.status = status
        self.pollURL = pollURL
        self.externalMeetingID = externalMeetingID
        self.rawResponseJSON = rawResponseJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        taskID = try container.decode(String.self, forKey: .taskID)
        status = try container.decode(MeetingSummaryStatus.self, forKey: .status)
        pollURL = try container.decode(String.self, forKey: .pollURL)
        externalMeetingID = try container.decode(String.self, forKey: .externalMeetingID)
        rawResponseJSON = ""
    }

    var debugSummary: String {
        "jobID=\(jobID) taskID=\(taskID) status=\(status.rawValue) pollURL=\(pollURL) externalMeetingID=\(externalMeetingID)"
    }
}

struct MeetingSummaryPollResponse: Decodable, Equatable {
    let jobID: String
    let externalMeetingID: String
    let taskID: String
    let status: MeetingSummaryStatus
    let meetingTitle: String
    let summaryText: String
    let fullText: String
    let result: MeetingSummaryResult?
    let shareURL: String
    let errorMessage: String
    let pollURL: String
    let rawResponseJSON: String
    
    private struct LossySummaryResult: Decodable {
        let value: MeetingSummaryResult?

        init(from decoder: Decoder) throws {
            value = try? MeetingSummaryResult(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case externalMeetingID = "external_meeting_id"
        case taskID = "task_id"
        case status
        case meetingTitle = "meeting_title"
        case summaryText = "summary_text"
        case fullText = "full_text"
        case result = "result_json"
        case shareURL = "share_url"
        case errorMessage = "error_message"
        case pollURL = "poll_url"
    }

    init(
        jobID: String,
        externalMeetingID: String,
        taskID: String,
        status: MeetingSummaryStatus,
        meetingTitle: String,
        summaryText: String,
        fullText: String,
        result: MeetingSummaryResult?,
        shareURL: String,
        errorMessage: String,
        pollURL: String,
        rawResponseJSON: String = ""
    ) {
        self.jobID = jobID
        self.externalMeetingID = externalMeetingID
        self.taskID = taskID
        self.status = status
        self.meetingTitle = meetingTitle
        self.summaryText = summaryText
        self.fullText = fullText
        self.result = result
        self.shareURL = shareURL
        self.errorMessage = errorMessage
        self.pollURL = pollURL
        self.rawResponseJSON = rawResponseJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        externalMeetingID = try container.decodeIfPresent(String.self, forKey: .externalMeetingID) ?? ""
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        status = try container.decode(MeetingSummaryStatus.self, forKey: .status)
        meetingTitle = try container.decodeIfPresent(String.self, forKey: .meetingTitle) ?? ""
        summaryText = try container.decodeIfPresent(String.self, forKey: .summaryText) ?? ""
        fullText = try container.decodeIfPresent(String.self, forKey: .fullText) ?? ""
        result = try container.decodeIfPresent(LossySummaryResult.self, forKey: .result)?.value
        shareURL = try container.decodeIfPresent(String.self, forKey: .shareURL) ?? ""
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        pollURL = try container.decodeIfPresent(String.self, forKey: .pollURL) ?? ""
        rawResponseJSON = ""
    }

    var debugSummary: String {
        "jobID=\(jobID) taskID=\(taskID) status=\(status.rawValue) meetingTitle=\(meetingTitle) summaryTextLength=\(summaryText.count) fullTextLength=\(fullText.count) shareURL=\(shareURL) errorMessageLength=\(errorMessage.count) pollURL=\(pollURL) externalMeetingID=\(externalMeetingID)"
    }
}

protocol MeetingSummaryClientProtocol {
    func submitMeeting(_ payload: MeetingSummarySubmissionPayload) async throws -> MeetingSummaryCreateResponse
    func fetchMeeting(jobID: String) async throws -> MeetingSummaryPollResponse
}

final class MeetingSummaryClient: MeetingSummaryClientProtocol {
    private let session: URLSession
    private let configProvider: MeetingSummaryConfigProviding
    private let decoder: JSONDecoder

    init(
        session: URLSession = .shared,
        configProvider: MeetingSummaryConfigProviding = AppPreferences.shared,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.session = session
        self.configProvider = configProvider
        self.decoder = decoder
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func submitMeeting(_ payload: MeetingSummarySubmissionPayload) async throws -> MeetingSummaryCreateResponse {
        let config = configProvider.meetingSummaryConfig
        guard config.isConfigured else {
            throw MeetingSummaryClientError.missingConfiguration
        }
        guard let url = config.endpointURL(path: "/api/integrations/neutype/meetings") else {
            throw MeetingSummaryClientError.invalidBaseURL(config.baseURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(config.trimmedAPIKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(payload.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try Self.makeMultipartBody(payload: payload, boundary: boundary)

        MeetingLog.info("Meeting summary submit request url=\(url.absoluteString) meetingID=\(payload.externalMeetingID)")
        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.httpResponse(from: response)
        MeetingLog.info(
            "Meeting summary submit response statusCode=\(httpResponse.statusCode) bodyPreview=\(Self.bodyPreview(from: data))"
        )
        try Self.ensureSuccess(httpResponse, data: data)
        let decoded = try decoder.decode(MeetingSummaryCreateResponse.self, from: data)
        let result = MeetingSummaryCreateResponse(
            jobID: decoded.jobID,
            taskID: decoded.taskID,
            status: decoded.status,
            pollURL: decoded.pollURL,
            externalMeetingID: decoded.externalMeetingID,
            rawResponseJSON: Self.rawResponseJSON(from: data)
        )
        MeetingLog.info("Meeting summary submit decoded \(result.debugSummary)")
        return result
    }

    func fetchMeeting(jobID: String) async throws -> MeetingSummaryPollResponse {
        let config = configProvider.meetingSummaryConfig
        guard config.isConfigured else {
            throw MeetingSummaryClientError.missingConfiguration
        }
        guard let url = config.endpointURL(path: "/api/integrations/neutype/meetings/\(jobID)") else {
            throw MeetingSummaryClientError.invalidBaseURL(config.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.setValue(config.trimmedAPIKey, forHTTPHeaderField: "X-Api-Key")

        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.httpResponse(from: response)
        MeetingLog.info(
            "Meeting summary poll response statusCode=\(httpResponse.statusCode) jobID=\(jobID) bodyPreview=\(Self.bodyPreview(from: data))"
        )
        try Self.ensureSuccess(httpResponse, data: data)
        let decoded = try decoder.decode(MeetingSummaryPollResponse.self, from: data)
        let result = MeetingSummaryPollResponse(
            jobID: decoded.jobID,
            externalMeetingID: decoded.externalMeetingID,
            taskID: decoded.taskID,
            status: decoded.status,
            meetingTitle: decoded.meetingTitle,
            summaryText: decoded.summaryText,
            fullText: decoded.fullText,
            result: decoded.result,
            shareURL: decoded.shareURL,
            errorMessage: decoded.errorMessage,
            pollURL: decoded.pollURL,
            rawResponseJSON: Self.rawResponseJSON(from: data)
        )
        MeetingLog.info("Meeting summary poll decoded \(result.debugSummary)")
        return result
    }

    private static func makeMultipartBody(
        payload: MeetingSummarySubmissionPayload,
        boundary: String
    ) throws -> Data {
        let audioData = try Data(contentsOf: payload.audioURL)
        var body = Data()

        appendField("external_meeting_id", value: payload.externalMeetingID, to: &body, boundary: boundary)
        appendField("meeting_title", value: payload.meetingTitle, to: &body, boundary: boundary)
        appendField("meeting_started_at", value: iso8601String(payload.meetingStartedAt), to: &body, boundary: boundary)
        appendField("meeting_ended_at", value: iso8601String(payload.meetingEndedAt), to: &body, boundary: boundary)
        appendField("meeting_timezone", value: payload.meetingTimeZone, to: &body, boundary: boundary)
        appendField("language", value: payload.language, to: &body, boundary: boundary)
        appendFile(
            name: "transcript_file",
            fileName: payload.transcriptFileName,
            mimeType: "text/plain",
            fileData: Data(payload.transcriptText.utf8),
            to: &body,
            boundary: boundary
        )
        appendFile(
            name: "audio_file",
            fileName: payload.audioURL.lastPathComponent,
            mimeType: mimeType(for: payload.audioURL.pathExtension),
            fileData: audioData,
            to: &body,
            boundary: boundary
        )

        body.append("--\(boundary)--\r\n")
        return body
    }

    private static func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
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

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func httpResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingSummaryClientError.invalidResponse
        }
        return httpResponse
    }

    private static func ensureSuccess(_ httpResponse: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown server error"
            MeetingLog.error(
                "Meeting summary request failed statusCode=\(httpResponse.statusCode) bodyPreview=\(bodyPreview(from: data))"
            )
            throw MeetingSummaryClientError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private static func bodyPreview(from data: Data, maxLength: Int = 1200) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body size=\(data.count)>"
        let compact = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compact.count > maxLength else { return compact }
        let index = compact.index(compact.startIndex, offsetBy: maxLength)
        return "\(compact[..<index])…"
    }

    private static func rawResponseJSON(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
