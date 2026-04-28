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

    func testTranscriptPaneIncludesLanguagePickerAndSelectedLanguageExport() throws {
        let source = try meetingDetailViewSource()

        XCTAssertFalse(
            source.contains("Picker(\"文字语言\", selection: $viewModel.selectedTranscriptLanguage)"),
            "Transcript pane should not render the redundant visible '文字语言' label."
        )
        XCTAssertTrue(
            source.contains("Picker(\"\", selection: $viewModel.selectedTranscriptLanguage)"),
            "Transcript pane should expose the original/translated transcript language picker without a visible label."
        )
        XCTAssertFalse(
            source.contains("Button(\"下载文字记录\")"),
            "Transcript export should no longer render a text button before the language picker."
        )
        XCTAssertTrue(
            source.contains("Image(systemName: \"square.and.arrow.down\")"),
            "Transcript export should render as an icon-only download button."
        )
        let pickerRange = try XCTUnwrap(
            source.range(of: "Picker(\"\", selection: $viewModel.selectedTranscriptLanguage)")
        )
        let exportIconRange = try XCTUnwrap(
            source.range(of: "Image(systemName: \"square.and.arrow.down\")")
        )
        XCTAssertLessThan(
            pickerRange.lowerBound,
            exportIconRange.lowerBound,
            "Transcript download icon should appear after the four language options."
        )
        XCTAssertTrue(
            source.contains("HStack(spacing: 0) {\n                        Picker(\"\", selection: $viewModel.selectedTranscriptLanguage)"),
            "Transcript language picker and download icon should sit next to each other without toolbar spacing."
        )
        XCTAssertTrue(
            source.contains("MeetingTranscriptLanguage.allCases"),
            "Transcript pane should render every supported transcript language option."
        )
        XCTAssertTrue(
            source.contains("viewModel.filteredTranscriptRows"),
            "Transcript pane should render language-projected transcript rows."
        )
        XCTAssertTrue(
            source.contains("viewModel.selectedTranscriptLanguage"),
            "Transcript export should use the selected transcript language."
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
