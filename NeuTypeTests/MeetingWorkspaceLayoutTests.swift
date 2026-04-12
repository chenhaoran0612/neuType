import XCTest
@testable import NeuType

final class MeetingWorkspaceLayoutTests: XCTestCase {
    func testSidebarWidthExpandsWithContainerWidthUntilClamp() {
        let compact = MeetingWorkspaceLayout(containerWidth: 1100, containerHeight: 760)
        let roomy = MeetingWorkspaceLayout(containerWidth: 1600, containerHeight: 900)

        XCTAssertEqual(compact.sidebarWidth, 460, accuracy: 0.1)
        XCTAssertEqual(roomy.sidebarWidth, 544, accuracy: 0.1)
    }

    func testPlayerWidthAndPaddingScaleWithContainer() {
        let compact = MeetingWorkspaceLayout(containerWidth: 1200, containerHeight: 760)
        let roomy = MeetingWorkspaceLayout(containerWidth: 1800, containerHeight: 960)

        XCTAssertGreaterThan(roomy.playerBarMaxWidth, compact.playerBarMaxWidth)
        XCTAssertGreaterThan(roomy.detailHorizontalPadding, compact.detailHorizontalPadding)
        XCTAssertGreaterThan(roomy.detailTitleFontSize, compact.detailTitleFontSize)
    }
}
