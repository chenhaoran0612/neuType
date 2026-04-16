import XCTest
@testable import NeuType

final class MeetingSessionControllerTests: XCTestCase {
    @MainActor
    func testShortcutStartsRecordingWithoutPresentingMeetingPage() async {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let recorder = ShortcutStubMeetingRecorder()
        let viewModel = MeetingRecorderViewModel(
            permissions: ShortcutStubMeetingPermissions(microphoneGranted: true, screenGranted: true),
            recorder: recorder
        )
        let controller = MeetingSessionController(
            recorderViewModel: viewModel,
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )

        await controller.handleShortcut()
        await Task.yield()

        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.overlayState, .recordingBar)
        XCTAssertEqual(overlayController.events, [.showRecordingBar])
        XCTAssertEqual(windowController.hideCalls, 1)
    }

    @MainActor
    func testShortcutDuringRecordingShowsStopConfirmationInsteadOfPresentingPage() async {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )
        controller.handleRecorderStateDidChange(.recording)
        controller.handleMeetingPageDismissed()

        await controller.handleShortcut()
        await Task.yield()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.overlayState, .stopConfirmation)
        XCTAssertEqual(overlayController.events.last, .showStopConfirmation)
    }

    @MainActor
    func testRecordingStateHidesMainPageAndShowsRecordingOverlay() {
        let eventRecorder = EventRecorder()
        let overlayController = StubMeetingOverlayController(eventRecorder: eventRecorder)
        let windowController = StubMeetingMainWindowController(eventRecorder: eventRecorder)
        let meetingWindowController = StubMeetingHistoryWindowController(eventRecorder: eventRecorder)
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )
        controller.present()

        controller.handleRecorderStateDidChange(.recording)

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.overlayState, .recordingBar)
        XCTAssertEqual(windowController.hideCalls, 0)
        XCTAssertEqual(overlayController.events, [])

        controller.handleMeetingPageDismissed()

        XCTAssertEqual(windowController.hideCalls, 1)
        XCTAssertEqual(overlayController.events, [.showRecordingBar])
        XCTAssertEqual(Array(eventRecorder.events.suffix(3)), [
            "meetingWindow.hide",
            "overlay.showRecordingBar",
            "window.hide"
        ])
    }

    @MainActor
    func testRequestStopConfirmationSwitchesToConfirmationOverlay() {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )
        controller.present()
        controller.handleRecorderStateDidChange(.recording)
        controller.handleMeetingPageDismissed()

        controller.requestStopConfirmation()

        XCTAssertEqual(controller.overlayState, .stopConfirmation)
        XCTAssertEqual(
            overlayController.events,
            [.showRecordingBar, .showStopConfirmation]
        )
    }

    @MainActor
    func testContinueMeetingReturnsToRecordingOverlay() {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )
        controller.present()
        controller.handleRecorderStateDidChange(.recording)
        controller.handleMeetingPageDismissed()
        controller.requestStopConfirmation()

        controller.continueMeetingRecording()

        XCTAssertEqual(controller.overlayState, .recordingBar)
        XCTAssertEqual(
            overlayController.events,
            [.showRecordingBar, .showStopConfirmation, .showRecordingBar]
        )
    }

    @MainActor
    func testCompletedStateShowsMainPageAndHidesOverlay() {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let alertPresenter = StubMeetingCompletionAlertPresenter()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController,
            completionAlertPresenter: alertPresenter
        )
        let meetingID = UUID()
        controller.present()
        controller.handleRecorderStateDidChange(.recording)
        controller.handleMeetingPageDismissed()

        controller.handleRecorderStateDidChange(.completed(meetingID))

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.overlayState, .hidden)
        XCTAssertEqual(controller.lastCompletedMeetingID, meetingID)
        XCTAssertEqual(windowController.showCalls, 0)
        XCTAssertEqual(meetingWindowController.showCalls, 2)
        XCTAssertEqual(
            overlayController.events,
            [.showRecordingBar, .hideOverlay]
        )
        XCTAssertTrue(alertPresenter.alertedMeetingTitles.isEmpty)
    }

    @MainActor
    func testSummaryCompletionShowsCompletionAlert() async throws {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let alertPresenter = StubMeetingCompletionAlertPresenter()
        let store = try MeetingRecordStore.inMemory()
        let meetingID = UUID()
        let meeting = MeetingRecord(
            id: meetingID,
            createdAt: Date(),
            title: "客户周会",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 1,
            summaryStatus: .processing
        )
        try await store.insertMeeting(meeting, segments: [])

        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController,
            store: store,
            completionAlertPresenter: alertPresenter
        )

        controller.handleRecorderStateDidChange(.completed(meetingID))
        try await store.updateSummaryResult(
            meetingID: meetingID,
            summaryText: "总结",
            fullText: "# 总结",
            result: .summaryFixture(),
            shareURL: "https://example.com/share"
        )
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(alertPresenter.alertedMeetingTitles, ["客户周会"])
    }

    @MainActor
    func testStartRecordingFromMeetingPageHidesMeetingWindowAndShowsOverlay() async {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let recorder = ShortcutStubMeetingRecorder()
        let viewModel = MeetingRecorderViewModel(
            permissions: ShortcutStubMeetingPermissions(microphoneGranted: true, screenGranted: true),
            recorder: recorder
        )
        let controller = MeetingSessionController(
            recorderViewModel: viewModel,
            overlayController: overlayController,
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )
        controller.present()

        await controller.startRecordingFromMeetingPage()
        await Task.yield()

        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.overlayState, .recordingBar)
        XCTAssertEqual(meetingWindowController.hideCalls, 1)
        XCTAssertEqual(overlayController.events, [.showRecordingBar])
        XCTAssertEqual(windowController.hideCalls, 1)
    }

    @MainActor
    func testPresentShowsMeetingWindow() {
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: StubMeetingOverlayController(),
            mainWindowController: StubMeetingMainWindowController(),
            meetingWindowController: StubMeetingHistoryWindowController()
        )

        controller.present()

        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testDismissHidesMeetingWindow() {
        let meetingWindowController = StubMeetingHistoryWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: StubMeetingOverlayController(),
            mainWindowController: StubMeetingMainWindowController(),
            meetingWindowController: meetingWindowController
        )
        controller.present()

        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(meetingWindowController.hideCalls, 1)
    }

    @MainActor
    func testDismissToHomeShowsMainWindowAndHidesMeetingWindow() {
        let windowController = StubMeetingMainWindowController()
        let meetingWindowController = StubMeetingHistoryWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: StubMeetingOverlayController(),
            mainWindowController: windowController,
            meetingWindowController: meetingWindowController
        )
        controller.present()

        controller.dismissToHome()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(meetingWindowController.hideCalls, 1)
        XCTAssertEqual(windowController.showCalls, 1)
    }
}

@MainActor
private final class StubMeetingCompletionAlertPresenter: MeetingCompletionAlertPresenting {
    private(set) var alertedMeetingTitles: [String] = []

    func showCompletionAlert(meetingTitle: String) {
        alertedMeetingTitles.append(meetingTitle)
    }
}

@MainActor
private final class StubMeetingOverlayController: MeetingOverlayControlling {
    enum Event: Equatable {
        case showRecordingBar
        case showStopConfirmation
        case hideOverlay
    }

    private(set) var events: [Event] = []
    private let eventRecorder: EventRecorder?

    init(eventRecorder: EventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func showRecordingBar(sessionController: MeetingSessionController) {
        events.append(.showRecordingBar)
        eventRecorder?.events.append("overlay.showRecordingBar")
    }

    func showStopConfirmation(sessionController: MeetingSessionController) {
        events.append(.showStopConfirmation)
        eventRecorder?.events.append("overlay.showStopConfirmation")
    }

    func hideOverlay() {
        events.append(.hideOverlay)
        eventRecorder?.events.append("overlay.hide")
    }
}

@MainActor
private final class StubMeetingMainWindowController: MeetingMainWindowControlling {
    private(set) var showCalls = 0
    private(set) var hideCalls = 0
    private let eventRecorder: EventRecorder?

    init(eventRecorder: EventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func showMainWindow() {
        showCalls += 1
        eventRecorder?.events.append("window.show")
    }

    func hideMainWindow() {
        hideCalls += 1
        eventRecorder?.events.append("window.hide")
    }
}

@MainActor
private final class StubMeetingHistoryWindowController: MeetingHistoryWindowControlling {
    private(set) var showCalls = 0
    private(set) var hideCalls = 0
    private let eventRecorder: EventRecorder?

    init(eventRecorder: EventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func showWindow(sessionController: MeetingSessionController) {
        showCalls += 1
        eventRecorder?.events.append("meetingWindow.show")
    }

    func hideWindow() {
        hideCalls += 1
        eventRecorder?.events.append("meetingWindow.hide")
    }
}

@MainActor
private final class EventRecorder {
    var events: [String] = []
}

private final class ShortcutStubMeetingPermissions: MeetingPermissionChecking {
    let microphoneGranted: Bool
    let screenGranted: Bool

    init(microphoneGranted: Bool, screenGranted: Bool) {
        self.microphoneGranted = microphoneGranted
        self.screenGranted = screenGranted
    }

    var isMicrophonePermissionGranted: Bool { microphoneGranted }
    var isScreenRecordingPermissionGranted: Bool { screenGranted }

    func requestMicrophonePermissionOrOpenSystemPreferences() {}
    func requestScreenRecordingPermissionOrOpenSystemPreferences() {}
}

private final class ShortcutStubMeetingRecorder: MeetingRecording {
    private(set) var startCalls = 0

    func startRecording() async throws {
        startCalls += 1
    }

    func stopRecording() async throws -> URL? {
        nil
    }

    func cancelRecording() {}
}

private extension MeetingSummaryResult {
    static func summaryFixture() -> MeetingSummaryResult {
        MeetingSummaryResult(
            meetingTitle: "客户周会",
            meetingStartedAt: Date(timeIntervalSince1970: 100),
            meetingEndedAt: Date(timeIntervalSince1970: 200),
            summary: "总结内容",
            keyPoints: ["要点 1"],
            actionItems: [
                MeetingSummaryActionItem(owner: "我方团队", task: "跟进 Demo", dueAt: "本周")
            ],
            risks: ["风险 1"],
            shareSummary: "一句话摘要"
        )
    }
}
