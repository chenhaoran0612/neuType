import AppKit
import SwiftUI

private final class MeetingHistoryWindow: NSWindow {
    var spaceKeyHandler: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 49,
           let spaceKeyHandler,
           spaceKeyHandler() {
            return
        }

        super.sendEvent(event)
    }
}

@MainActor
protocol MeetingHistoryWindowControlling: AnyObject {
    func showWindow(sessionController: MeetingSessionController)
    func hideWindow()
}

@MainActor
final class MeetingHistoryWindowManager: NSObject, MeetingHistoryWindowControlling, NSWindowDelegate {
    static let shared = MeetingHistoryWindowManager()

    private weak var sessionController: MeetingSessionController?
    private var window: MeetingHistoryWindow?
    private var hostingView: NSHostingView<AnyView>?

    func showWindow(sessionController: MeetingSessionController) {
        self.sessionController = sessionController
        let window = ensureWindow(sessionController: sessionController)
        MeetingLog.info("Meeting history window show frame=\(NSStringFromRect(window.frame))")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hideWindow() {
        MeetingLog.info("Meeting history window hide")
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MeetingLog.info("Meeting history window close requested")
        sessionController?.dismissToHome()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        MeetingLog.info("Meeting history window moved frame=\(NSStringFromRect(window.frame))")
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        MeetingLog.info("Meeting history window resized frame=\(NSStringFromRect(window.frame))")
    }

    private func ensureWindow(sessionController: MeetingSessionController) -> MeetingHistoryWindow {
        if let window {
            window.appearance = NSAppearance(named: .aqua)
            let rootView = AnyView(
                MeetingRootView()
                    .preferredColorScheme(.light)
                    .environmentObject(sessionController)
            )
            if let hostingView {
                hostingView.rootView = rootView
            } else {
                let hostingView = NSHostingView(rootView: rootView)
                window.contentView = hostingView
                self.hostingView = hostingView
            }
            return window
        }

        let window = MeetingHistoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1540, height: 980),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "会议记录"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.isMovableByWindowBackground = true
        window.isMovable = true
        window.minSize = NSSize(width: 1260, height: 820)
        window.setFrameAutosaveName("MeetingHistoryWindow")
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.spaceKeyHandler = { [weak self, weak window] in
            guard let self, let window, window.isKeyWindow else {
                return false
            }

            let modifierFlags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            MeetingLog.info(
                "Meeting history window space keyDown modifiers=\(modifierFlags.rawValue) firstResponder=\(String(describing: type(of: window.firstResponder)))"
            )

            if modifierFlags.contains(.command)
                || modifierFlags.contains(.option)
                || modifierFlags.contains(.control)
                || modifierFlags.contains(.shift) {
                return false
            }

            if self.focusIsInTextInput(window: window) {
                MeetingLog.info("Meeting history window space key ignored because focus is in text input")
                return false
            }

            MeetingLog.info("Meeting playback toggled by space key")
            NotificationCenter.default.post(name: .toggleMeetingPlayback, object: nil)
            return true
        }
        let hostingView = NSHostingView(
            rootView: AnyView(
                MeetingRootView()
                    .preferredColorScheme(.light)
                    .environmentObject(sessionController)
            )
        )
        window.contentView = hostingView

        self.window = window
        self.hostingView = hostingView
        return window
    }

    private func focusIsInTextInput(window: NSWindow) -> Bool {
        if let responder = window.firstResponder as? NSTextView {
            return responder.isEditable || responder.isSelectable
        }

        return false
    }
}
