import AVFoundation
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
        let recorder = StubMeetingRecorder(stopRecordingURL: makeTemporaryAudioURL(duration: 1))
        let store = try! MeetingRecordStore.inMemory()
        let transcriptionService = StubMeetingTranscriptionService()
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: recorder,
            store: store,
            transcriptionService: transcriptionService,
            remoteCoordinatorFactory: nil
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
        let audioURL = makeTemporaryAudioURL(duration: 1)
        let recorder = StubMeetingRecorder(stopRecordingURL: audioURL)
        let store = try MeetingRecordStore.inMemory()
        let transcriptionService = StubMeetingTranscriptionService(delayNanoseconds: 200_000_000)
        let summaryService = StubMeetingSummaryService()
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: recorder,
            store: store,
            transcriptionService: transcriptionService,
            summaryService: summaryService,
            remoteCoordinatorFactory: nil
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

        let didFinishPostProcessing = await waitUntil {
            transcriptionService.transcribedAudioURLs == [audioURL]
                && summaryService.submittedMeetingIDs == [meetingID]
        }
        XCTAssertTrue(didFinishPostProcessing)
        XCTAssertEqual(transcriptionService.transcribedAudioURLs, [audioURL])
        XCTAssertEqual(summaryService.submittedMeetingIDs, [meetingID])
    }

    @MainActor
    func testStopRecordingUsesRemoteCoordinatorInsteadOfDirectTranscribe() async throws {
        let permissions = StubMeetingPermissions(
            microphoneGranted: true,
            screenGranted: true
        )
        let audioURL = makeTemporaryAudioURL(duration: 1)
        let recorder = StubMeetingRecorder(
            stopRecordingURL: audioURL,
            artifactsToEmitOnStop: [
                .sealedChunk(.init(chunkIndex: 0, startMS: 0, endMS: 300_000, fileURL: audioURL)),
                .finalAudio(.init(fileURL: audioURL, durationMS: 1_000))
            ]
        )
        let store = try MeetingRecordStore.inMemory()
        let transcriptionService = StubMeetingTranscriptionService()
        let coordinator = StubMeetingRemoteSessionCoordinator(result: .remoteFixture())
        let viewModel = MeetingRecorderViewModel(
            permissions: permissions,
            recorder: recorder,
            store: store,
            transcriptionService: transcriptionService,
            summaryService: StubMeetingSummaryService(),
            remoteCoordinatorFactory: { _ in coordinator }
        )

        await viewModel.startRecording()
        await viewModel.stopRecording()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transcriptionService.transcribedMeetingIDs.count, 0)
        XCTAssertEqual(coordinator.handledChunks.map(\.chunkIndex), [0])
        XCTAssertEqual(coordinator.finalizeCalls.count, 1)
        XCTAssertEqual(coordinator.finalizeCalls.first?.expectedChunkCount, 1)
        XCTAssertEqual(coordinator.pollCalls, 1)
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

private final class StubMeetingRecorder: MeetingRecording, MeetingRecordingArtifactProducing, @unchecked Sendable {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private let stopRecordingURL: URL?
    private let artifactsToEmitOnStop: [MeetingRecordingArtifact]
    var artifactHandler: (@Sendable (MeetingRecordingArtifact) async -> Void)?

    init(
        stopRecordingURL: URL? = nil,
        artifactsToEmitOnStop: [MeetingRecordingArtifact] = []
    ) {
        self.stopRecordingURL = stopRecordingURL
        self.artifactsToEmitOnStop = artifactsToEmitOnStop
    }

    func startRecording() async throws {
        startCalls += 1
    }

    func stopRecording() async throws -> URL? {
        stopCalls += 1
        for artifact in artifactsToEmitOnStop {
            await artifactHandler?(artifact)
        }
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

private final class StubMeetingRemoteSessionCoordinator: MeetingRemoteSessionCoordinating, @unchecked Sendable {
    let result: RemoteMeetingTranscriptResult
    private(set) var handledChunks: [MeetingRecordingChunkArtifact] = []
    private(set) var finalizeCalls: [(fullAudioURL: URL, expectedChunkCount: Int)] = []
    private(set) var pollCalls = 0

    init(result: RemoteMeetingTranscriptResult) {
        self.result = result
    }

    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async {
        handledChunks.append(artifact)
    }

    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws {
        finalizeCalls.append((fullAudioURL, expectedChunkCount))
    }

    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult {
        pollCalls += 1
        return result
    }
}

private final class StubMeetingAppController: MeetingAppControlling {
    private(set) var relaunchCalls = 0

    func relaunch() {
        relaunchCalls += 1
    }
}

private func makeTemporaryAudioURL(duration: TimeInterval) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let frameCount = AVAudioFrameCount((duration * format.sampleRate).rounded())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    if let channel = buffer.int16ChannelData?.pointee {
        for index in 0 ..< Int(frameCount) {
            channel[index] = Int16(index % Int(Int16.max))
        }
    }
    let file = try? AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
    try? file?.write(from: buffer)
    return url
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    intervalNanoseconds: UInt64 = 20_000_000,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return condition()
}

private extension RemoteMeetingTranscriptResult {
    static func remoteFixture() -> RemoteMeetingTranscriptResult {
        .init(
            fullText: "hello world",
            segments: [
                .init(sequence: 0, speakerLabel: "Speaker 1", startMS: 0, endMS: 1_000, text: "hello"),
                .init(sequence: 1, speakerLabel: "Speaker 2", startMS: 1_000, endMS: 2_000, text: "world"),
            ]
        )
    }
}
