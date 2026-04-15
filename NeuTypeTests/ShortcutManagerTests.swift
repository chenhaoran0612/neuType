import XCTest
@testable import NeuType

final class ShortcutManagerTests: XCTestCase {
    func testKeyDownStartsWhenIndicatorIsNotActive() {
        XCTAssertEqual(
            ShortcutManager.HotkeyAction.resolveOnKeyDown(hasActiveIndicator: false),
            .startRecording
        )
    }

    func testKeyDownDoesNothingWhenIndicatorIsAlreadyActive() {
        XCTAssertEqual(
            ShortcutManager.HotkeyAction.resolveOnKeyDown(hasActiveIndicator: true),
            .none
        )
    }

    func testKeyUpStopsWhenIndicatorIsActive() {
        XCTAssertEqual(
            ShortcutManager.HotkeyAction.resolveOnKeyUp(hasActiveIndicator: true),
            .stopRecording
        )
    }

    func testKeyUpDoesNothingWhenIndicatorIsNotActive() {
        XCTAssertEqual(
            ShortcutManager.HotkeyAction.resolveOnKeyUp(hasActiveIndicator: false),
            .none
        )
    }
}
