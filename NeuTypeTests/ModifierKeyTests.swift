import CoreGraphics
import XCTest
@testable import NeuType

final class ModifierKeyTests: XCTestCase {
    func testFnMatchesFlagsChangedWhenFunctionFlagIsPresentWithoutFnKeyCode() {
        XCTAssertTrue(
            ModifierKey.fn.matchesFlagsChangedEvent(
                keyCode: 0,
                flags: CGEventFlags(arrayLiteral: .maskSecondaryFn)
            )
        )
    }

    func testFnMatchesFlagsChangedOnKeyUpWhenFnKeyCodeRemainsButFlagIsGone() {
        XCTAssertTrue(
            ModifierKey.fn.matchesFlagsChangedEvent(
                keyCode: ModifierKey.fn.keyCode,
                flags: CGEventFlags()
            )
        )
    }

    func testFnProcessesCGEventReleaseWhilePreviouslyPressedEvenWithoutFnKeyCode() {
        XCTAssertTrue(
            ModifierKey.fn.shouldProcessFlagsChangedEvent(
                keyCode: 0,
                flags: CGEventFlags(),
                wasPressed: true
            )
        )
    }

    func testNonFnStillRequiresExactKeyCodeMatch() {
        XCTAssertFalse(
            ModifierKey.leftControl.matchesFlagsChangedEvent(
                keyCode: 0,
                flags: CGEventFlags(arrayLiteral: .maskControl)
            )
        )
    }

    func testFnMatchesNSEventFunctionModifierWithoutFnKeyCode() {
        XCTAssertTrue(
            ModifierKey.fn.matchesFlagsChangedEvent(
                keyCode: 0,
                flags: NSEvent.ModifierFlags(arrayLiteral: .function)
            )
        )
    }

    func testFnMatchesNSEventKeyUpWhenFnKeyCodeRemainsButFlagIsGone() {
        XCTAssertTrue(
            ModifierKey.fn.matchesFlagsChangedEvent(
                keyCode: ModifierKey.fn.keyCode,
                flags: NSEvent.ModifierFlags()
            )
        )
    }

    func testFnProcessesNSEventReleaseWhilePreviouslyPressedEvenWithoutFnKeyCode() {
        XCTAssertTrue(
            ModifierKey.fn.shouldProcessFlagsChangedEvent(
                keyCode: 0,
                flags: NSEvent.ModifierFlags(),
                wasPressed: true
            )
        )
    }

    func testNonFnStillRequiresExactKeyCodeMatchForNSEventFlags() {
        XCTAssertFalse(
            ModifierKey.leftControl.matchesFlagsChangedEvent(
                keyCode: 0,
                flags: NSEvent.ModifierFlags(arrayLiteral: .control)
            )
        )
    }
}
