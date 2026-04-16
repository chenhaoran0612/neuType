import XCTest

final class MeetingRootViewTests: XCTestCase {
    func testMeetingRootViewSourceKeepsDirectRecorderEntryPoints() throws {
        let testsFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NeuType/Meetings/Views/MeetingRootView.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MeetingRecorderView("), "Meeting workspace should keep a direct embedded recorder entry instead of forcing users to rely only on the shortcut.")
        XCTAssertTrue(source.contains("startRecordingFromMeetingPage"), "Meeting workspace should expose a direct start-recording action from the page UI.")
    }
}
