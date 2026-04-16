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
protocol MeetingCompletionAlertPresenting: AnyObject {
    func showCompletionAlert(meetingTitle: String)
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
final class MeetingCompletionAlertPresenter: MeetingCompletionAlertPresenting {
    static let shared = MeetingCompletionAlertPresenter()

    func showCompletionAlert(meetingTitle: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "会议记录完成，请查看。"
        alert.informativeText = meetingTitle.isEmpty ? "总结与代办已经生成完成。" : "《\(meetingTitle)》的总结与代办已经生成完成。"
        alert.addButton(withTitle: "查看")

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
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
    private let meetingWindowController: MeetingHistoryWindowControlling
    private let store: MeetingRecordStore
    private let completionAlertPresenter: MeetingCompletionAlertPresenting
    private var cancellables = Set<AnyCancellable>()
    private var recordsDidChangeObserver: NSObjectProtocol?
    private var pendingCompletionAlertMeetingID: UUID?
    private var completionAlertsShown = Set<UUID>()

    init() {
        self.recorderViewModel = MeetingRecorderViewModel()
        self.overlayController = MeetingOverlayWindowManager.shared
        self.mainWindowController = MeetingMainWindowController.shared
        self.meetingWindowController = MeetingHistoryWindowManager.shared
        self.store = .shared
        self.completionAlertPresenter = MeetingCompletionAlertPresenter.shared
        observeRecorderState()
        observeMeetingUpdates()
    }

    init(recorderViewModel: MeetingRecorderViewModel) {
        self.recorderViewModel = recorderViewModel
        self.overlayController = MeetingOverlayWindowManager.shared
        self.mainWindowController = MeetingMainWindowController.shared
        self.meetingWindowController = MeetingHistoryWindowManager.shared
        self.store = .shared
        self.completionAlertPresenter = MeetingCompletionAlertPresenter.shared
        observeRecorderState()
        observeMeetingUpdates()
    }

    init(
        recorderViewModel: MeetingRecorderViewModel,
        overlayController: MeetingOverlayControlling,
        mainWindowController: MeetingMainWindowControlling,
        meetingWindowController: MeetingHistoryWindowControlling,
        store: MeetingRecordStore = .shared,
        completionAlertPresenter: MeetingCompletionAlertPresenting? = nil
    ) {
        self.recorderViewModel = recorderViewModel
        self.overlayController = overlayController
        self.mainWindowController = mainWindowController
        self.meetingWindowController = meetingWindowController
        self.store = store
        self.completionAlertPresenter = completionAlertPresenter ?? MeetingCompletionAlertPresenter.shared
        observeRecorderState()
        observeMeetingUpdates()
    }

    deinit {
        if let recordsDidChangeObserver {
            NotificationCenter.default.removeObserver(recordsDidChangeObserver)
        }
    }

    func present() {
        MeetingLog.info("Present meeting history page")
        isPresented = true
        meetingWindowController.showWindow(sessionController: self)
    }

    func dismiss() {
        MeetingLog.info("Dismiss meeting history page")
        isPresented = false
        meetingWindowController.hideWindow()
    }

    func dismissToHome() {
        MeetingLog.info("Dismiss meeting history page and return to home")
        dismiss()
        mainWindowController.showMainWindow()
        NotificationCenter.default.post(name: .returnToHome, object: nil)
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
        meetingWindowController.hideWindow()

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
            pendingCompletionAlertMeetingID = meetingID
            completionAlertsShown.remove(meetingID)
            MeetingLog.info("Meeting completed id=\(meetingID.uuidString) -> hide overlay and show history")
            overlayState = .hidden
            overlayController.hideOverlay()
            present()
            Task { @MainActor [weak self] in
                await self?.checkCompletionAlertIfNeeded()
            }
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

    private func observeMeetingUpdates() {
        recordsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .meetingRecordsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.checkCompletionAlertIfNeeded()
            }
        }
    }

    private func checkCompletionAlertIfNeeded() async {
        guard let meetingID = pendingCompletionAlertMeetingID else { return }
        guard !completionAlertsShown.contains(meetingID) else { return }
        guard let meeting = try? await store.fetchMeeting(id: meetingID) else { return }
        guard meeting.status == .completed, meeting.summaryStatus == .completed else { return }

        completionAlertsShown.insert(meetingID)
        pendingCompletionAlertMeetingID = nil
        MeetingLog.info("Meeting summary completed alert meetingID=\(meetingID.uuidString)")
        completionAlertPresenter.showCompletionAlert(meetingTitle: meeting.title)
    }
}
