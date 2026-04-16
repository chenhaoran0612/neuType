import SwiftUI

struct MeetingRecorderView: View {
    @EnvironmentObject private var meetingSession: MeetingSessionController
    @ObservedObject var viewModel: MeetingRecorderViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("会议录制")
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
                        Button("重新打开 NeuType") {
                            viewModel.relaunchApplication()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("开始") {
                    Task { await viewModel.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStartDisabled)

                Button("停止") {
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
            return "准备录制麦克风和系统音频。"
        case .permissionBlocked(.microphone):
            return "需要先授予麦克风权限。"
        case .permissionBlocked(.screenRecording):
            return "采集系统音频需要屏幕录制权限。请在系统设置授权后重新打开 NeuType。"
        case .recording:
            return "正在录制会议。"
        case .processing:
            return "正在处理会议音频。"
        case .completed:
            return "会议录制完成。"
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
            return "授予麦克风权限"
        case .screenRecording:
            return "授予屏幕录制权限"
        }
    }
}
