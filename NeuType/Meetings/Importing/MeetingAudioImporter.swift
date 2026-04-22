import Foundation

protocol MeetingAudioImporting {
    func importAudio(from sourceURL: URL) throws -> URL
}

struct DefaultMeetingAudioImporter: MeetingAudioImporting {
    let meetingsDirectory: URL

    init(meetingsDirectory: URL = MeetingRecord.meetingsDirectory) {
        self.meetingsDirectory = meetingsDirectory
    }

    func importAudio(from sourceURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: meetingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = destinationWAVURL(for: sourceURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        if sourceURL.pathExtension.lowercased() == "wav" {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }

        try transcodeToWAV(sourceURL: sourceURL, destinationURL: destinationURL)
        return destinationURL
    }

    private func destinationWAVURL(for sourceURL: URL) -> URL {
        meetingsDirectory.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")
    }

    private func transcodeToWAV(sourceURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            sourceURL.path,
            destinationURL.path,
            "-f", "WAVE",
            "-d", "LEI16"
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destinationURL.path) else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MeetingAudioImporter",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage?.isEmpty == false
                        ? errorMessage!
                        : "Failed to convert imported audio to WAV."
                ]
            )
        }
    }
}
