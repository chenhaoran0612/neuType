import Foundation

struct MeetingVibeVoiceConfig: Equatable {
    let pythonPath: String
    let runnerPath: String
    let modelID: String

    func resolvedRunnerScriptPath(
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        bundleResourcePath: String? = Bundle.main.resourcePath
    ) -> String {
        let trimmedRunnerPath = runnerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRunnerPath.isEmpty else { return "" }

        if trimmedRunnerPath.hasPrefix("/") {
            return trimmedRunnerPath
        }

        if let bundleResourcePath {
            let bundledPath = URL(fileURLWithPath: bundleResourcePath)
                .appendingPathComponent(trimmedRunnerPath)
                .path
            if FileManager.default.fileExists(atPath: bundledPath) {
                return bundledPath
            }
        }

        return URL(fileURLWithPath: currentDirectoryPath)
            .appendingPathComponent(trimmedRunnerPath)
            .path
    }
}

protocol MeetingVibeVoiceConfigProviding {
    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { get }
}

extension AppPreferences: MeetingVibeVoiceConfigProviding {
    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig {
        MeetingVibeVoiceConfig(
            pythonPath: meetingVibeVoicePythonPath.trimmingCharacters(in: .whitespacesAndNewlines),
            runnerPath: meetingVibeVoiceRunnerPath,
            modelID: meetingVibeVoiceModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
