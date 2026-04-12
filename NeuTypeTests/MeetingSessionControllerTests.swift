import XCTest
@testable import NeuType

final class MeetingSessionControllerTests: XCTestCase {
    @MainActor
    func testShortcutStartsRecordingWithoutPresentingMeetingPage() async {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let recorder = ShortcutStubMeetingRecorder()
        let viewModel = MeetingRecorderViewModel(
            permissions: ShortcutStubMeetingPermissions(microphoneGranted: true, screenGranted: true),
            recorder: recorder
        )
        let controller = MeetingSessionController(
            recorderViewModel: viewModel,
            overlayController: overlayController,
            mainWindowController: windowController
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
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController
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
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController
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
        XCTAssertEqual(Array(eventRecorder.events.suffix(2)), [
            "overlay.showRecordingBar",
            "window.hide"
        ])
    }

    @MainActor
    func testRequestStopConfirmationSwitchesToConfirmationOverlay() {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController
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
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController
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
    func testRecordingLimitShowsStopConfirmationAndBlocksContinue() async {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let recorder = ShortcutStubMeetingRecorder()
        let viewModel = MeetingRecorderViewModel(
            permissions: ShortcutStubMeetingPermissions(microphoneGranted: true, screenGranted: true),
            recorder: recorder
        )
        let controller = MeetingSessionController(
            recorderViewModel: viewModel,
            overlayController: overlayController,
            mainWindowController: windowController
        )

        await controller.handleShortcut()
        viewModel.handleRecordingElapsedTime(3600)
        await Task.yield()

        XCTAssertEqual(controller.overlayState, .stopConfirmation)
        XCTAssertEqual(controller.stopConfirmationReason, .timeLimitReached)

        controller.continueMeetingRecording()

        XCTAssertEqual(controller.overlayState, .stopConfirmation)
    }

    @MainActor
    func testCompletedStateShowsMainPageAndHidesOverlay() {
        let overlayController = StubMeetingOverlayController()
        let windowController = StubMeetingMainWindowController()
        let controller = MeetingSessionController(
            recorderViewModel: MeetingRecorderViewModel(),
            overlayController: overlayController,
            mainWindowController: windowController
        )
        let meetingID = UUID()
        controller.present()
        controller.handleRecorderStateDidChange(.recording)
        controller.handleMeetingPageDismissed()

        controller.handleRecorderStateDidChange(.completed(meetingID))

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.overlayState, .hidden)
        XCTAssertEqual(controller.lastCompletedMeetingID, meetingID)
        XCTAssertEqual(windowController.showCalls, 2)
        XCTAssertEqual(
            overlayController.events,
            [.showRecordingBar, .hideOverlay]
        )
    }

    @MainActor
    func testPresentDoesNotPublishShortcutToggle() {
        let controller = MeetingSessionController()

        controller.present()

        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testDismissHidesMeetingSheet() {
        let controller = MeetingSessionController()
        controller.present()

        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
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
