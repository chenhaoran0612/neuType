import XCTest
@testable import NeuType

final class AppPermissionGateTests: XCTestCase {
    func testBlocksMainInterfaceWhenMicrophonePermissionIsMissing() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: false,
            isAccessibilityPermissionGranted: true,
            isScreenRecordingPermissionGranted: true,
            screenRecordingPermissionState: .granted
        )

        XCTAssertTrue(gate.blocksMainInterface)
    }

    func testBlocksMainInterfaceWhenAccessibilityPermissionIsMissing() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: true,
            isAccessibilityPermissionGranted: false,
            isScreenRecordingPermissionGranted: true,
            screenRecordingPermissionState: .granted
        )

        XCTAssertTrue(gate.blocksMainInterface)
    }

    func testBlocksMainInterfaceWhenScreenRecordingPermissionIsMissing() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: true,
            isAccessibilityPermissionGranted: true,
            isScreenRecordingPermissionGranted: false,
            screenRecordingPermissionState: .needsAuthorization
        )

        XCTAssertTrue(gate.blocksMainInterface)
    }

    func testDoesNotBlockMainInterfaceWhenAllPermissionsAreGranted() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: true,
            isAccessibilityPermissionGranted: true,
            isScreenRecordingPermissionGranted: true,
            screenRecordingPermissionState: .granted
        )

        XCTAssertFalse(gate.blocksMainInterface)
    }

    func testDoesNotBlockMainInterfaceWhenScreenRecordingNeedsRelaunch() {
        let gate = AppPermissionGate(
            isMicrophonePermissionGranted: true,
            isAccessibilityPermissionGranted: true,
            isScreenRecordingPermissionGranted: false,
            screenRecordingPermissionState: .needsRelaunch
        )

        XCTAssertFalse(gate.blocksMainInterface)
    }

    @MainActor
    func testPermissionsViewIncludesThreePermissionRows() {
        let manager = PermissionsManager()

        let items = PermissionsView.items(for: manager)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(
            items.map(\.title),
            ["Microphone Access", "Accessibility Access", "Screen Recording Access"]
        )
    }

    @MainActor
    func testPermissionsViewKeepsAccessibilityInGrantFlowWhenAccessIsMissing() {
        let manager = PermissionsManager()
        manager.isAccessibilityPermissionGranted = false
        manager.accessibilityPermissionState = .needsAuthorization

        let items = PermissionsView.items(for: manager)
        let accessibilityItem = try! XCTUnwrap(items.first(where: { $0.id == .accessibility }))

        XCTAssertEqual(accessibilityItem.description, "Required for global keyboard shortcuts")
        XCTAssertEqual(accessibilityItem.buttonTitle, "Grant Access")
    }

    func testAccessibilityStateIsGrantedWhenPermissionIsGranted() {
        XCTAssertEqual(
            AccessibilityPermissionState.resolve(
                isGranted: true,
                requiresRelaunch: true
            ),
            .granted
        )
    }

    func testAccessibilityStateRequiresAuthorizationBeforeRelaunchIsNeeded() {
        XCTAssertEqual(
            AccessibilityPermissionState.resolve(
                isGranted: false,
                requiresRelaunch: false
            ),
            .needsAuthorization
        )
    }

    func testScreenRecordingStateIsGrantedWhenPermissionIsGranted() {
        XCTAssertEqual(
            ScreenRecordingPermissionState.resolve(
                isGranted: true,
                requiresRelaunch: true
            ),
            .granted
        )
    }

    func testScreenRecordingStateRequiresAuthorizationBeforePrompt() {
        XCTAssertEqual(
            ScreenRecordingPermissionState.resolve(
                isGranted: false,
                requiresRelaunch: false
            ),
            .needsAuthorization
        )
    }

    func testScreenRecordingStateRequiresRelaunchWhenAccessNeedsProcessRestart() {
        XCTAssertEqual(
            ScreenRecordingPermissionState.resolve(
                isGranted: false,
                requiresRelaunch: true
            ),
            .needsRelaunch
        )
    }

    func testScreenRecordingRequestActionIsGrantedWhenPreflightSucceeds() {
        XCTAssertEqual(
            ScreenRecordingPermissionRequestAction.resolve(
                preflightGranted: true,
                requestGranted: nil
            ),
            .granted
        )
    }

    func testScreenRecordingRequestActionRelaunchesWhenPromptReturnsGranted() {
        XCTAssertEqual(
            ScreenRecordingPermissionRequestAction.resolve(
                preflightGranted: false,
                requestGranted: true
            ),
            .relaunch
        )
    }

    func testScreenRecordingRequestActionOpensSystemPreferencesWhenPromptDoesNotGrant() {
        XCTAssertEqual(
            ScreenRecordingPermissionRequestAction.resolve(
                preflightGranted: false,
                requestGranted: false
            ),
            .openSystemPreferences
        )
    }
}
