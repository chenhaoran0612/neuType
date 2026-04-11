import SwiftUI

struct MeetingRecorderView: View {
    @StateObject private var viewModel = MeetingRecorderViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Meeting Recorder")
                .font(.title2.weight(.semibold))

            Text(statusText)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Start") {
                    Task { await viewModel.startRecording() }
                }
                .buttonStyle(.borderedProminent)

                Button("Stop") {
                    Task { await viewModel.stopRecording() }
                }
                .buttonStyle(.bordered)
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
            return "Screen recording permission is required for system audio capture."
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
}
