import XCTest
@testable import NeuType

final class AppPermissionGateTests: XCTestCase {
    func testBlocksMainInterfaceWhenMicrophonePermissionIsMissing() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: false,
            isAccessibilityPermissionGranted: true
        )

        XCTAssertTrue(gate.blocksMainInterface)
    }

    func testDoesNotBlockMainInterfaceWhenOnlyAccessibilityPermissionIsMissing() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: true,
            isAccessibilityPermissionGranted: false
        )

        XCTAssertFalse(gate.blocksMainInterface)
    }
}
