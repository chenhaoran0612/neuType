import XCTest

final class MeetingOverlayWindowManagerTests: XCTestCase {
    func testOverlayManagerSourceDoesNotUseMoveToActiveSpace() throws {
        let testsFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NeuType/Meetings/Views/MeetingOverlayWindowManager.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains(".moveToActiveSpace"),
            "Overlay panel must not use .moveToActiveSpace because it crashes AppKit validation for the nonactivating panel configuration."
        )
    }
}
