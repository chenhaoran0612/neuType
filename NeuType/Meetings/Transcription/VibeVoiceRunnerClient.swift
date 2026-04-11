import Foundation

enum VibeVoiceRunnerError: LocalizedError {
    case invalidRunnerPath(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRunnerPath(let path):
            "VibeVoice runner script not found at \(path)"
        case .processFailed(let message):
            message
        }
    }
}

final class VibeVoiceRunnerClient {
    private let processFactory: () -> Process
    private let decoder: JSONDecoder

    init(
        processFactory: @escaping () -> Process = { Process() },
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.processFactory = processFactory
        self.decoder = decoder
    }

    func transcribe(audioURL: URL, hotwords: [String] = []) async throws -> MeetingTranscriptionResult {
        let scriptPath = resolvedRunnerScriptPath()
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw VibeVoiceRunnerError.invalidRunnerPath(scriptPath)
        }

        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: AppPreferences.shared.meetingVibeVoicePythonPath)
        process.arguments = [scriptPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let request = VibeVoiceRunnerRequest(
            audioPath: audioURL.path,
            modelID: AppPreferences.shared.meetingVibeVoiceModelID,
            hotwords: hotwords
        )
        let requestData = try JSONEncoder().encode(request)
        inputPipe.fileHandleForWriting.write(requestData)
        try inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown VibeVoice runner failure"
            throw VibeVoiceRunnerError.processFailed(message)
        }

        return try Self.decodeResult(from: outputData, decoder: decoder)
    }

    static func decodeResult(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> MeetingTranscriptionResult {
        try decoder.decode(MeetingTranscriptionResult.self, from: data)
    }

    private func resolvedRunnerScriptPath() -> String {
        let configured = AppPreferences.shared.meetingVibeVoiceRunnerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return "" }

        if configured.hasPrefix("/") {
            return configured
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(configured)
            .path
    }
}

private struct VibeVoiceRunnerRequest: Encodable {
    let audioPath: String
    let modelID: String
    let hotwords: [String]

    enum CodingKeys: String, CodingKey {
        case audioPath = "audio_path"
        case modelID = "model_id"
        case hotwords
    }
}
