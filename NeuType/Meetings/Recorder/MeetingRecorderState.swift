import Foundation

enum MeetingPermissionKind: Equatable {
    case microphone
    case screenRecording
}

enum MeetingRecorderState: Equatable {
    case idle
    case permissionBlocked(MeetingPermissionKind)
    case recording
    case processing
    case completed(UUID)
    case failed(String)
}
