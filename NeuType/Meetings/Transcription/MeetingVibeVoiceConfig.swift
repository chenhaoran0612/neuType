import Foundation

struct MeetingVibeVoiceConfig: Equatable {
    let baseURL: String
    let apiPrefix: String
    let contextInfo: String
    let maxNewTokens: Int
    let temperature: Double
    let topP: Double
    let doSample: Bool
    let repetitionPenalty: Double

    func endpointURL(path: String) -> URL? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else { return nil }

        let normalizedBase = trimmedBaseURL.hasSuffix("/") ? trimmedBaseURL : "\(trimmedBaseURL)/"
        let normalizedPrefix = apiPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

protocol MeetingVibeVoiceConfigProviding {
    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { get }
}

extension AppPreferences: MeetingVibeVoiceConfigProviding {
    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig {
        MeetingVibeVoiceConfig(
            baseURL: meetingVibeVoiceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiPrefix: meetingVibeVoiceAPIPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            contextInfo: meetingVibeVoiceContextInfo,
            maxNewTokens: meetingVibeVoiceMaxNewTokens,
            temperature: meetingVibeVoiceTemperature,
            topP: meetingVibeVoiceTopP,
            doSample: meetingVibeVoiceDoSample,
            repetitionPenalty: meetingVibeVoiceRepetitionPenalty
        )
    }
}
