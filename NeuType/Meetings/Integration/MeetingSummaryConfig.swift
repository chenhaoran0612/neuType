import Foundation

struct MeetingSummaryConfig: Equatable {
    static let defaultBaseURL = "https://ai-worker.neuxnet.com"

    let baseURL: String
    let apiKey: String

    var normalizedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultBaseURL : trimmed
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !trimmedAPIKey.isEmpty
    }

    func endpointURL(path: String) -> URL? {
        guard let base = URL(string: normalizedBaseURL) else { return nil }
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.appending(path: trimmedPath)
    }
}

protocol MeetingSummaryConfigProviding {
    var meetingSummaryConfig: MeetingSummaryConfig { get }
}

extension AppPreferences: MeetingSummaryConfigProviding {
    var meetingSummaryConfig: MeetingSummaryConfig {
        MeetingSummaryConfig(
            baseURL: meetingSummaryBaseURL,
            apiKey: meetingSummaryAPIKey
        )
    }
}
