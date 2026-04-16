import XCTest

final class MeetingDetailViewSourceTests: XCTestCase {
    func testSummaryPanePrefersFullTextOverStructuredSummaryCards() throws {
        let testsFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NeuType/Meetings/Views/MeetingDetailView.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let fullTextCondition = "if !viewModel.summaryFullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {"
        let fullTextMarkdown = "MarkdownTextView(markdown: viewModel.summaryFullText)"
        let structuredFallback = "} else if let result = viewModel.summaryResult {"

        XCTAssertTrue(
            source.contains(fullTextCondition),
            "Summary pane should explicitly prefer fullText when it is available."
        )

        let markdownRange = try XCTUnwrap(
            source.range(of: fullTextMarkdown),
            "Summary pane should render the fullText markdown block."
        )
        let structuredFallbackRange = try XCTUnwrap(
            source.range(of: structuredFallback),
            "Summary pane should fall back to structured summary cards only when fullText is unavailable."
        )

        XCTAssertLessThan(
            markdownRange.lowerBound,
            structuredFallbackRange.lowerBound,
            "Summary pane should render fullText before falling back to structured summary cards."
        )
    }
}
