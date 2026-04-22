import XCTest

final class MeetingRootViewSourceTests: XCTestCase {
    func testEmptyDetailAreaShowsExplicitEmptyStateCopy() throws {
        let source = try meetingRootViewSource()

        XCTAssertTrue(
            source.contains("Text(\"暂无会议记录\")"),
            "Empty detail area should show an explicit empty-state title."
        )
        XCTAssertTrue(
            source.contains("开始会议录制或导入音频后，这里会显示文字记录、播放控件和总结结果。"),
            "Empty detail area should explain what will appear after recording/import."
        )
        XCTAssertFalse(
            source.contains("MeetingRecorderView(viewModel: meetingSession.recorderViewModel)"),
            "Empty detail area should no longer embed the recorder card."
        )
    }

    private func meetingRootViewSource() throws -> String {
        let testsFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NeuType/Meetings/Views/MeetingRootView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
