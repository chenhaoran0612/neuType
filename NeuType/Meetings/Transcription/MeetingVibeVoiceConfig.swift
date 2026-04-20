import Foundation

struct MeetingVibeVoiceConfig: Equatable, Sendable {
    let baseURL: String
    let apiPrefix: String
    var apiKey: String = ""
    let contextInfo: String
    let maxNewTokens: Int
    let temperature: Double
    let topP: Double
    let doSample: Bool
    let repetitionPenalty: Double

    func endpointURL(path: String) -> URL? {
        endpointURL(path: path, ignoreLegacyGradioPrefix: false)
    }

    func chatCompletionsURL() -> URL? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.lowercased().hasSuffix("/v1/chat/completions") {
            return URL(string: trimmedBaseURL)
        }
        return endpointURL(path: "v1/chat/completions", ignoreLegacyGradioPrefix: true)
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpointURL(path: String, ignoreLegacyGradioPrefix: Bool) -> URL? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else { return nil }

        let normalizedBase = trimmedBaseURL.hasSuffix("/") ? trimmedBaseURL : "\(trimmedBaseURL)/"
        let rawPrefix = apiPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPrefix: String
        if ignoreLegacyGradioPrefix && rawPrefix == "gradio_api" {
            normalizedPrefix = ""
        } else {
            normalizedPrefix = rawPrefix
        }
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let fullPath = normalizedPrefix.isEmpty
            ? normalizedPath
            : "\(normalizedPrefix)/\(normalizedPath)"

        return URL(string: normalizedBase)?.appending(path: fullPath)
    }

    func combinedContextInfo(hotwords: [String]) -> String {
        let configuredLines = contextInfo
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let merged = (configuredLines + hotwords)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let unique = merged.filter { seen.insert($0).inserted }
        return unique.joined(separator: "\n")
    }
}

protocol MeetingVibeVoiceConfigProviding: Sendable {
    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { get }
}

extension AppPreferences: MeetingVibeVoiceConfigProviding {
    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig {
        MeetingVibeVoiceConfig(
            baseURL: meetingVibeVoiceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiPrefix: meetingVibeVoiceAPIPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: meetingVibeVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? meetingSummaryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                : meetingVibeVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            contextInfo: meetingVibeVoiceContextInfo,
            maxNewTokens: meetingVibeVoiceMaxNewTokens,
            temperature: meetingVibeVoiceTemperature,
            topP: meetingVibeVoiceTopP,
            doSample: meetingVibeVoiceDoSample,
            repetitionPenalty: meetingVibeVoiceRepetitionPenalty
        )
    }
}
