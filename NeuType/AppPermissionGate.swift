import Foundation

struct AppPermissionGate {
    let isMicrophonePermissionGranted: Bool
    let isAccessibilityPermissionGranted: Bool
    let isScreenRecordingPermissionGranted: Bool
    let screenRecordingPermissionState: ScreenRecordingPermissionState

    init(
        isMicrophonePermissionGranted: Bool,
        isAccessibilityPermissionGranted: Bool,
        isScreenRecordingPermissionGranted: Bool,
        screenRecordingPermissionState: ScreenRecordingPermissionState = .granted
    ) {
        self.isMicrophonePermissionGranted = isMicrophonePermissionGranted
        self.isAccessibilityPermissionGranted = isAccessibilityPermissionGranted
        self.isScreenRecordingPermissionGranted = isScreenRecordingPermissionGranted
        self.screenRecordingPermissionState = screenRecordingPermissionState
    }

    var blocksMainInterface: Bool {
        !isMicrophonePermissionGranted ||
        !isAccessibilityPermissionGranted ||
        (screenRecordingPermissionState != .granted &&
         screenRecordingPermissionState != .needsRelaunch &&
         !isScreenRecordingPermissionGranted)
    }
}
