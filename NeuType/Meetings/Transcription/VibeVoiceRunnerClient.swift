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

protocol VibeVoiceRunning {
    func transcribe(audioURL: URL, hotwords: [String]) async throws -> MeetingTranscriptionResult
}

final class VibeVoiceRunnerClient: VibeVoiceRunning {
    private let processFactory: () -> Process
    private let decoder: JSONDecoder
    private let configProvider: MeetingVibeVoiceConfigProviding
    private let configureProcess: (Process) -> Void

    init(
        processFactory: @escaping () -> Process = { Process() },
        decoder: JSONDecoder = JSONDecoder(),
        configProvider: MeetingVibeVoiceConfigProviding = AppPreferences.shared,
        configureProcess: @escaping (Process) -> Void = { _ in }
    ) {
        self.processFactory = processFactory
        self.decoder = decoder
        self.configProvider = configProvider
        self.configureProcess = configureProcess
    }

    func transcribe(audioURL: URL, hotwords: [String] = []) async throws -> MeetingTranscriptionResult {
        let config = configProvider.meetingVibeVoiceConfig
        let scriptPath = config.resolvedRunnerScriptPath()
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw VibeVoiceRunnerError.invalidRunnerPath(scriptPath)
        }

        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: config.pythonPath)
        process.arguments = [scriptPath]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        configureProcess(process)
        process.environment = Self.runnerEnvironment(
            base: process.environment ?? ProcessInfo.processInfo.environment
        )

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let request = VibeVoiceRunnerRequest(
            audioPath: audioURL.path,
            modelID: config.modelID,
            hotwords: hotwords
        )
        let requestData = try JSONEncoder().encode(request)
        inputPipe.fileHandleForWriting.write(requestData)
        try inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            throw VibeVoiceRunnerError.processFailed(Self.failureMessage(from: errorData))
        }

        return try Self.decodeResult(from: outputData, decoder: decoder)
    }

    static func runnerEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["TRANSFORMERS_NO_ADVISORY_WARNINGS"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONWARNINGS"] = "ignore"
        return environment
    }

    static func failureMessage(from data: Data) -> String {
        guard let stderrOutput = String(data: data, encoding: .utf8) else {
            return "Unknown VibeVoice runner failure"
        }

        let lines = stderrOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.last ?? "Unknown VibeVoice runner failure"
    }

    static func decodeResult(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> MeetingTranscriptionResult {
        try decoder.decode(MeetingTranscriptionResult.self, from: data)
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
