import XCTest
import KeyboardShortcuts
@testable import NeuType

final class MeetingShortcutValidationTests: XCTestCase {
    func testMeetingShortcutRejectsDictationShortcutCollision() {
        let validator = MeetingShortcutValidator(
            dictationShortcut: .init(.backtick, modifiers: .option)
        )

        XCTAssertFalse(validator.canUse(.init(.backtick, modifiers: .option)))
        XCTAssertTrue(validator.canUse(.init(.m, modifiers: [.option, .shift])))
    }
}
