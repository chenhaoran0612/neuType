import SwiftUI

struct MeetingRecorderView: View {
    @EnvironmentObject private var meetingSession: MeetingSessionController
    @ObservedObject var viewModel: MeetingRecorderViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Meeting Recorder")
                .font(.title2.weight(.semibold))

            Text(statusText)
                .foregroundColor(.secondary)

            if let blockedPermission = blockedPermission {
                HStack(spacing: 12) {
                    Button(buttonTitle(for: blockedPermission)) {
                        viewModel.requestPermission(for: blockedPermission)
                    }
                    .buttonStyle(.bordered)

                    if blockedPermission == .screenRecording {
                        Button("Relaunch NeuType") {
                            viewModel.relaunchApplication()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Start") {
                    Task { await viewModel.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStartDisabled)

                Button("Stop") {
                    meetingSession.requestStopConfirmation()
                }
                .buttonStyle(.bordered)
                .disabled(isStopDisabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle:
            return "Ready to record microphone and system audio."
        case .permissionBlocked(.microphone):
            return "Microphone permission is required."
        case .permissionBlocked(.screenRecording):
            return "Screen recording permission is required for system audio capture. After granting access in System Settings, relaunch NeuType."
        case .recording:
            return "Recording in progress."
        case .processing:
            return "Processing meeting audio."
        case .completed:
            return "Meeting complete."
        case .failed(let message):
            return message
        }
    }

    private var isStartDisabled: Bool {
        if case .recording = viewModel.state { return true }
        if case .processing = viewModel.state { return true }
        return false
    }

    private var isStopDisabled: Bool {
        if case .recording = viewModel.state { return false }
        return true
    }

    private var blockedPermission: MeetingPermissionKind? {
        guard case .permissionBlocked(let permission) = viewModel.state else {
            return nil
        }
        return permission
    }

    private func buttonTitle(for permission: MeetingPermissionKind) -> String {
        switch permission {
        case .microphone:
            return "Grant Microphone Access"
        case .screenRecording:
            return "Grant Screen Recording Access"
        }
    }
}
