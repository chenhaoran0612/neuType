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
        XCTAssertEqual(permissions.screenPermissionRequests, 1)
    }

    @MainActor
    func testStartRecordingRequestsMicrophonePermissionWhenMissing() async {
        let permissions = StubMeetingPermissions(
            microphoneGranted: false,
            screenGranted: true
        )
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: StubMeetingRecorder()
        )

        await viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .permissionBlocked(.microphone))
        XCTAssertEqual(permissions.microphonePermissionRequests, 1)
    }

    @MainActor
    func testRelaunchApplicationDelegatesToAppController() {
        let appController = StubMeetingAppController()
        let viewModel = MeetingRecorderViewModel(
            permissions: StubMeetingPermissions(microphoneGranted: true, screenGranted: true),
            recorder: StubMeetingRecorder(),
            appController: appController
        )

        viewModel.relaunchApplication()

        XCTAssertEqual(appController.relaunchCalls, 1)
    }

    @MainActor
    func testHandleShortcutStartsRecordingWhenIdle() async {
        let permissions = StubMeetingPermissions(
            microphoneGranted: true,
            screenGranted: true
        )
        let recorder = StubMeetingRecorder()
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: recorder
        )

        await viewModel.handleShortcut()

        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.stopCalls, 0)
        XCTAssertEqual(viewModel.state, .recording)
    }

    @MainActor
    func testHandleShortcutStopsRecordingWhenAlreadyRecording() async {
        let permissions = StubMeetingPermissions(
            microphoneGranted: true,
            screenGranted: true
        )
        let recorder = StubMeetingRecorder(stopRecordingURL: temporaryAudioURL())
        let store = try! MeetingRecordStore.inMemory()
        let transcriptionService = StubMeetingTranscriptionService()
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: recorder,
            store: store,
            transcriptionService: transcriptionService
        )
        await viewModel.startRecording()

        await viewModel.handleShortcut()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(transcriptionService.transcribedMeetingIDs.count, 1)
        guard case .completed(let meetingID) = viewModel.state else {
            return XCTFail("Expected completed state")
        }

        let savedMeeting = try? await store.fetchMeeting(id: meetingID)
        XCTAssertEqual(savedMeeting?.status, .processing)
    }

    @MainActor
    func testStopRecordingCreatesMeetingAndTransitionsToCompletedImmediately() async throws {
        let previousBaseURL = AppPreferences.shared.meetingSummaryBaseURL
        let previousAPIKey = AppPreferences.shared.meetingSummaryAPIKey
        AppPreferences.shared.meetingSummaryBaseURL = "https://ai-worker.neuxnet.com"
        AppPreferences.shared.meetingSummaryAPIKey = "ntm_test"
        defer {
            AppPreferences.shared.meetingSummaryBaseURL = previousBaseURL
            AppPreferences.shared.meetingSummaryAPIKey = previousAPIKey
        }

        let permissions = StubMeetingPermissions(
            microphoneGranted: true,
            screenGranted: true
        )
        let audioURL = temporaryAudioURL()
        let recorder = StubMeetingRecorder(stopRecordingURL: audioURL)
        let store = try MeetingRecordStore.inMemory()
        let transcriptionService = StubMeetingTranscriptionService(delayNanoseconds: 200_000_000)
        let summaryService = StubMeetingSummaryService()
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: recorder,
            store: store,
            transcriptionService: transcriptionService,
            summaryService: summaryService
        )

        await viewModel.startRecording()
        await viewModel.stopRecording()

        guard case .completed(let meetingID) = viewModel.state else {
            return XCTFail("Expected completed state")
        }

        let savedMeeting = try await store.fetchMeeting(id: meetingID)
        XCTAssertEqual(savedMeeting?.audioFileName, audioURL.lastPathComponent)
        XCTAssertEqual(savedMeeting?.status, .processing)
        XCTAssertFalse(savedMeeting?.title.hasPrefix("Meeting ") ?? true)

        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(transcriptionService.transcribedAudioURLs, [audioURL])
        XCTAssertEqual(summaryService.submittedMeetingIDs, [meetingID])
    }
}

private final class StubMeetingPermissions: MeetingPermissionChecking {
    let microphoneGranted: Bool
    let screenGranted: Bool
    private(set) var microphonePermissionRequests = 0
    private(set) var screenPermissionRequests = 0

    init(microphoneGranted: Bool, screenGranted: Bool) {
        self.microphoneGranted = microphoneGranted
        self.screenGranted = screenGranted
    }

    var isMicrophonePermissionGranted: Bool { microphoneGranted }
    var isScreenRecordingPermissionGranted: Bool { screenGranted }

    func requestMicrophonePermissionOrOpenSystemPreferences() {
        microphonePermissionRequests += 1
    }

    func requestScreenRecordingPermissionOrOpenSystemPreferences() {
        screenPermissionRequests += 1
    }
}

private final class StubMeetingRecorder: MeetingRecording, @unchecked Sendable {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private let stopRecordingURL: URL?

    init(stopRecordingURL: URL? = nil) {
        self.stopRecordingURL = stopRecordingURL
    }

    func startRecording() async throws {
        startCalls += 1
    }

    func stopRecording() async throws -> URL? {
        stopCalls += 1
        return stopRecordingURL
    }

    func cancelRecording() {}
}

private final class StubMeetingTranscriptionService: MeetingTranscribing, @unchecked Sendable {
    private(set) var transcribedMeetingIDs: [UUID] = []
    private(set) var transcribedAudioURLs: [URL] = []
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(meetingID: UUID, audioURL: URL) async throws {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        transcribedMeetingIDs.append(meetingID)
        transcribedAudioURLs.append(audioURL)
    }
}

private final class StubMeetingSummaryService: MeetingSummarizing, @unchecked Sendable {
    private(set) var submittedMeetingIDs: [UUID] = []

    func submitMeeting(meetingID: UUID) async throws {
        submittedMeetingIDs.append(meetingID)
    }

    func resumeMeeting(meetingID: UUID) async throws {}
}

private final class StubMeetingAppController: MeetingAppControlling {
    private(set) var relaunchCalls = 0

    func relaunch() {
        relaunchCalls += 1
    }
}

private func temporaryAudioURL() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    _ = FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
    return url
}
