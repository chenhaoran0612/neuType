import Foundation
import XCTest
@testable import NeuType

final class MeetingAudioImporterTests: XCTestCase {
    func testImportAudioKeepsWavAsWav() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceURL = repoRoot()
            .appendingPathComponent("jfk.wav")

        let meetingsDirectory = temp.appendingPathComponent("meetings", isDirectory: true)
        let importer = DefaultMeetingAudioImporter(meetingsDirectory: meetingsDirectory)
        let importedURL = try importer.importAudio(from: sourceURL)

        XCTAssertEqual(importedURL.pathExtension.lowercased(), "wav")
        XCTAssertTrue(Self.isRIFFWAV(importedURL))
        XCTAssertGreaterThan(try Data(contentsOf: importedURL).count, 44)
    }

    func testImportAudioConvertsMP3ToWAV() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceURL = repoRoot()
            .appendingPathComponent("NeuType")
            .appendingPathComponent("notification.mp3")

        let meetingsDirectory = temp.appendingPathComponent("meetings", isDirectory: true)
        let importer = DefaultMeetingAudioImporter(meetingsDirectory: meetingsDirectory)
        let importedURL = try importer.importAudio(from: sourceURL)

        XCTAssertEqual(importedURL.pathExtension.lowercased(), "wav")
        XCTAssertTrue(Self.isRIFFWAV(importedURL))
        XCTAssertGreaterThan(try Data(contentsOf: importedURL).count, 44)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func isRIFFWAV(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else {
            return false
        }
        return data.prefix(4) == Data("RIFF".utf8)
            && data[8..<12] == Data("WAVE".utf8)
    }
}
