import XCTest
@testable import NeuType

final class MeetingRecorderViewModelTests: XCTestCase {
    @MainActor
    func testStartRecordingMovesToPermissionBlockedWhenScreenRecordingMissing() async {
        let permissions = StubMeetingPermissions(
            microphoneGranted: true,
            screenGranted: false
        )
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: StubMeetingRecorder()
        )

        await viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .permissionBlocked(.screenRecording))
    }
}

private struct StubMeetingPermissions: MeetingPermissionChecking {
    let microphoneGranted: Bool
    let screenGranted: Bool

    var isMicrophonePermissionGranted: Bool { microphoneGranted }
    var isScreenRecordingPermissionGranted: Bool { screenGranted }
}

private final class StubMeetingRecorder: MeetingRecording {
    func startRecording() async throws {}
    func stopRecording() async throws -> URL? { nil }
    func cancelRecording() {}
}
