import Foundation

protocol MeetingPermissionChecking {
    var isMicrophonePermissionGranted: Bool { get }
    var isScreenRecordingPermissionGranted: Bool { get }
}

extension PermissionsManager: MeetingPermissionChecking {}

@MainActor
final class MeetingRecorderViewModel: ObservableObject {
    @Published private(set) var state: MeetingRecorderState = .idle

    private let permissions: MeetingPermissionChecking
    private let recorder: MeetingRecording

    init(
        permissions: MeetingPermissionChecking = PermissionsManager(),
        recorder: MeetingRecording = MeetingRecorder()
    ) {
        self.permissions = permissions
        self.recorder = recorder
    }

    func startRecording() async {
        guard permissions.isMicrophonePermissionGranted else {
            state = .permissionBlocked(.microphone)
            return
        }

        guard permissions.isScreenRecordingPermissionGranted else {
            state = .permissionBlocked(.screenRecording)
            return
        }

        do {
            try await recorder.startRecording()
            state = .recording
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        do {
            state = .processing
            _ = try await recorder.stopRecording()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancelRecording() {
        recorder.cancelRecording()
        state = .idle
    }
}
