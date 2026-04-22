import XCTest

final class MeetingDetailViewSourceTests: XCTestCase {
    func testSummaryPaneRendersOnlyFullTextMarkdown() throws {
        let source = try meetingDetailViewSource()

        XCTAssertTrue(
            source.contains("MarkdownTextView(markdown: viewModel.summaryFullText)"),
            "Summary pane should render full_text markdown directly."
        )
        XCTAssertFalse(
            source.contains("else if let result = viewModel.summaryResult"),
            "Summary pane should not fall back to structured summary cards when full_text is empty."
        )
    }

    func testPlaybackBarIncludesDownloadOriginalAudioButton() throws {
        let source = try meetingDetailViewSource()

        XCTAssertTrue(
            source.contains("Label(\"下载原始音频\", systemImage: \"arrow.down.circle\")"),
            "Playback bar should expose a download-original-audio button."
        )
        XCTAssertTrue(
            source.contains("exportOriginalAudio()"),
            "Playback bar should wire the download button to the original audio export action."
        )
    }

    func testSummaryHeaderIncludesLogButtonAndSheet() throws {
        let source = try meetingDetailViewSource()

        XCTAssertTrue(
            source.contains("Label(\"日志\", systemImage: \"doc.text.magnifyingglass\")"),
            "Summary header should expose a 日志 button next to share actions."
        )
        XCTAssertTrue(
            source.contains(".sheet(isPresented: $isShowingSummaryLog)"),
            "Summary header should present the request JSON in a sheet."
        )
        XCTAssertTrue(
            source.contains("viewModel.summaryLogDisplayText"),
            "Summary log sheet should render the latest raw summary response JSON or a historical-data fallback message."
        )
    }

    func testTranscriptProcessingUsesLogIconSheetInsteadOfInlinePanel() throws {
        let source = try meetingDetailViewSource()

        XCTAssertTrue(
            source.contains(".sheet(isPresented: $showingTranscriptLogs)"),
            "Transcript pane should present request logs in a sheet."
        )
        XCTAssertTrue(
            source.contains("Image(systemName: \"doc.text.magnifyingglass\")"),
            "Transcript processing card should expose a log icon."
        )
        XCTAssertFalse(
            source.contains("case .processing:\n                VStack(alignment: .leading, spacing: 16) {\n                    transcriptStatusPanel"),
            "Transcript processing state should no longer reserve a second inline stack for logs."
        )
    }

    private func meetingDetailViewSource() throws -> String {
        let testsFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NeuType/Meetings/Views/MeetingDetailView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
