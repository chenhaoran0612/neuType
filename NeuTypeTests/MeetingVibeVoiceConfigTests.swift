import XCTest
@testable import NeuType

final class MeetingVibeVoiceConfigTests: XCTestCase {
    func testRelativeRunnerPathResolvesAgainstWorkingDirectory() {
        let config = MeetingVibeVoiceConfig(
            pythonPath: "/usr/bin/python3",
            runnerPath: "Scripts/vibevoice_asr_runner.py",
            modelID: "microsoft/VibeVoice-ASR-HF"
        )

        let resolvedPath = config.resolvedRunnerScriptPath(
            currentDirectoryPath: "/tmp/NeuType"
        )

        XCTAssertEqual(resolvedPath, "/tmp/NeuType/Scripts/vibevoice_asr_runner.py")
    }

    func testRelativeRunnerPathPrefersBundledResourceWhenAvailable() throws {
        let resourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scriptsDirectory = resourceRoot.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let bundledScriptURL = scriptsDirectory.appendingPathComponent("vibevoice_asr_runner.py")
        _ = FileManager.default.createFile(atPath: bundledScriptURL.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: resourceRoot) }

        let config = MeetingVibeVoiceConfig(
            pythonPath: "/usr/bin/python3",
            runnerPath: "Scripts/vibevoice_asr_runner.py",
            modelID: "microsoft/VibeVoice-ASR-HF"
        )

        let resolvedPath = config.resolvedRunnerScriptPath(
            currentDirectoryPath: "/",
            bundleResourcePath: resourceRoot.path
        )

        XCTAssertEqual(resolvedPath, bundledScriptURL.path)
    }

    func testAbsoluteRunnerPathRemainsUnchanged() {
        let config = MeetingVibeVoiceConfig(
            pythonPath: "/usr/bin/python3",
            runnerPath: "/opt/vibevoice/runner.py",
            modelID: "microsoft/VibeVoice-ASR-HF"
        )

        let resolvedPath = config.resolvedRunnerScriptPath(
            currentDirectoryPath: "/tmp/NeuType"
        )

        XCTAssertEqual(resolvedPath, "/opt/vibevoice/runner.py")
    }
}
