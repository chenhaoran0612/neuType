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

        let destinationURL = meetingsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
