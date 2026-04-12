import Combine
import AppKit
import Foundation

enum MeetingOverlayState: Equatable {
    case hidden
    case recordingBar
    case stopConfirmation
}

enum MeetingStopConfirmationReason: Equatable {
    case manual
    case timeLimitReached
}

@MainActor
protocol MeetingOverlayControlling: AnyObject {
    func showRecordingBar(sessionController: MeetingSessionController)
    func showStopConfirmation(sessionController: MeetingSessionController)
    func hideOverlay()
}

@MainActor
protocol MeetingMainWindowControlling: AnyObject {
    func showMainWindow()
    func hideMainWindow()
}

@MainActor
final class MeetingMainWindowController: MeetingMainWindowControlling {
    static let shared = MeetingMainWindowController()

    func showMainWindow() {
        MeetingLog.info("Main window show requested")
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.showMainWindow()
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    func hideMainWindow() {
        MeetingLog.info("Main window hide requested")
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            NSApplication.shared.keyWindow?.orderOut(nil)
            return
        }

        appDelegate.hideMainWindow()
    }
}

@MainActor
final class MeetingSessionController: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var overlayState: MeetingOverlayState = .hidden
    @Published private(set) var lastCompletedMeetingID: UUID?
    @Published private(set) var stopConfirmationReason: MeetingStopConfirmationReason = .manual

    let recorderViewModel: MeetingRecorderViewModel
    private let overlayController: MeetingOverlayControlling
    private let mainWindowController: MeetingMainWindowControlling
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.recorderViewModel = MeetingRecorderViewModel()
        self.overlayController = MeetingOverlayWindowManager.shared
        self.mainWindowController = MeetingMainWindowController.shared
        observeRecorderState()
    }

    init(recorderViewModel: MeetingRecorderViewModel) {
        self.recorderViewModel = recorderViewModel
        self.overlayController = MeetingOverlayWindowManager.shared
        self.mainWindowController = MeetingMainWindowController.shared
        observeRecorderState()
    }

    init(
        recorderViewModel: MeetingRecorderViewModel,
        overlayController: MeetingOverlayControlling,
        mainWindowController: MeetingMainWindowControlling
    ) {
        self.recorderViewModel = recorderViewModel
        self.overlayController = overlayController
        self.mainWindowController = mainWindowController
        observeRecorderState()
    }

    func present() {
        MeetingLog.info("Present meeting history page")
        mainWindowController.showMainWindow()
        isPresented = true
    }

    func dismiss() {
        MeetingLog.info("Dismiss meeting history page")
        isPresented = false
    }

    func handleShortcut() async {
        MeetingLog.info("Shortcut received overlayState=\(String(describing: overlayState)) recorderState=\(String(describing: recorderViewModel.state))")

        switch overlayState {
        case .recordingBar:
            MeetingLog.info("Shortcut while recording -> show stop confirmation")
            requestStopConfirmation()
            return
        case .stopConfirmation:
            MeetingLog.info("Shortcut ignored while stop confirmation visible")
            return
        case .hidden:
            break
        }

        MeetingLog.info("Shortcut starting meeting recording directly")
        await recorderViewModel.startRecording()
    }

    func requestStopConfirmation() {
        requestStopConfirmation(reason: .manual)
    }

    func requestStopConfirmation(reason: MeetingStopConfirmationReason) {
        guard overlayState == .recordingBar else { return }
        MeetingLog.info("Switch overlay -> stop confirmation reason=\(String(describing: reason))")
        stopConfirmationReason = reason
        overlayState = .stopConfirmation
        overlayController.showStopConfirmation(sessionController: self)
    }

    func continueMeetingRecording() {
        guard stopConfirmationReason != .timeLimitReached else { return }
        guard overlayState == .stopConfirmation else { return }
        MeetingLog.info("Continue meeting recording from stop confirmation")
        stopConfirmationReason = .manual
        overlayState = .recordingBar
        overlayController.showRecordingBar(sessionController: self)
    }

    func finishMeetingRecording() async {
        MeetingLog.info("Finalize meeting recording")
        await recorderViewModel.stopRecording()
    }

    func reopenMainMeetingPage() {
        MeetingLog.info("Reopen meeting history page from overlay")
        present()
    }

    func handleMeetingPageDismissed() {
        MeetingLog.info("Meeting history page dismissed overlayState=\(String(describing: overlayState))")
        isPresented = false

        switch overlayState {
        case .recordingBar:
            MeetingLog.info("Show recording overlay after page dismissal")
            overlayController.showRecordingBar(sessionController: self)
            mainWindowController.hideMainWindow()
        case .stopConfirmation:
            MeetingLog.info("Show stop confirmation overlay after page dismissal")
            overlayController.showStopConfirmation(sessionController: self)
            mainWindowController.hideMainWindow()
        case .hidden:
            break
        }
    }

    func handleRecorderStateDidChange(_ state: MeetingRecorderState) {
        MeetingLog.info("Recorder state -> \(String(describing: state)) isPresented=\(isPresented)")
        switch state {
        case .recording:
            stopConfirmationReason = .manual
            overlayState = .recordingBar
            if isPresented {
                MeetingLog.info("Recording started while history page visible -> dismiss page first")
                isPresented = false
            } else {
                MeetingLog.info("Recording started without history page -> show overlay immediately")
                handleMeetingPageDismissed()
            }
        case .processing:
            MeetingLog.info("Processing started -> hide overlay")
            overlayState = .hidden
            overlayController.hideOverlay()
        case .completed(let meetingID):
            lastCompletedMeetingID = meetingID
            MeetingLog.info("Meeting completed id=\(meetingID.uuidString) -> hide overlay and show history")
            overlayState = .hidden
            overlayController.hideOverlay()
            present()
        case .failed, .idle, .permissionBlocked:
            MeetingLog.info("Recorder returned to non-recording state -> hide overlay and show history")
            overlayState = .hidden
            overlayController.hideOverlay()
            present()
        }
    }

    private func observeRecorderState() {
        recorderViewModel.$state
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleRecorderStateDidChange(state)
            }
            .store(in: &cancellables)

        recorderViewModel.$hasReachedRecordingLimit
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.requestStopConfirmation(reason: .timeLimitReached)
            }
            .store(in: &cancellables)
    }
}
