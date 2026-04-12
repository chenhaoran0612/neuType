import Foundation

struct AppPermissionGate {
    let isMicrophonePermissionGranted: Bool
    let isAccessibilityPermissionGranted: Bool

    var blocksMainInterface: Bool {
        !isMicrophonePermissionGranted
    }
}
