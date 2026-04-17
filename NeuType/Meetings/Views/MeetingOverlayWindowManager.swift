import AppKit
import SwiftUI

@MainActor
final class MeetingOverlayWindowManager: NSObject, MeetingOverlayControlling, NSWindowDelegate {
    static let shared = MeetingOverlayWindowManager()

    private var window: MeetingOverlayPanel?
    private var didPositionWindow = false

    private override init() {
        super.init()
    }

    func showRecordingBar(sessionController: MeetingSessionController) {
        MeetingLog.info("Overlay manager show recording bar")
        presentOnNextRunLoop(
            size: NSSize(width: 300, height: 56),
            centeredVertically: false,
            rootView: MeetingOverlayContainerView()
                .environmentObject(sessionController)
        )
    }

    func showStopConfirmation(sessionController: MeetingSessionController) {
        MeetingLog.info("Overlay manager show stop confirmation")
        presentOnNextRunLoop(
            size: NSSize(width: 300, height: 132),
            centeredVertically: false,
            rootView: MeetingOverlayContainerView()
                .environmentObject(sessionController)
        )
    }

    func hideOverlay() {
        MeetingLog.info("Overlay manager hide overlay")
        window?.orderOut(nil)
        didPositionWindow = false
    }

    private func presentOnNextRunLoop<Content: View>(
        size: NSSize,
        centeredVertically: Bool,
        rootView: Content
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.present(
                size: size,
                centeredVertically: centeredVertically,
                rootView: rootView
            )
        }
    }

    private func present<Content: View>(
        size: NSSize,
        centeredVertically: Bool,
        rootView: Content
    ) {
        let window = ensureWindow()
        installContent(rootView: rootView, in: window)
        let screen = preferredScreen()
        let frame = targetFrame(for: size, window: window, screen: screen, centeredVertically: centeredVertically)
        MeetingLog.info("Overlay present size=\(Int(size.width))x\(Int(size.height)) frame=\(NSStringFromRect(frame)) screen=\(screen?.localizedName ?? "nil")")

        window.setContentSize(size)
        window.setFrame(frame, display: false)
        MeetingLog.info("Overlay frontmost app before show=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") activationPolicy=\(NSApp.activationPolicy().rawValue)")
        window.level = .popUpMenu
        window.orderFrontRegardless()
        window.makeKey()
        window.invalidateShadow()
        MeetingLog.info("Overlay visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) windowNumber=\(window.windowNumber) frontmostAppAfterShow=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak window] in
            guard let window else { return }
            if window.isVisible {
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    private func installContent<Content: View>(
        rootView: Content,
        in window: MeetingOverlayPanel
    ) {
        MeetingLog.info("Install overlay hosting view")
        window.contentView = WindowDraggableHostingView(rootView: rootView)
    }

    private func ensureWindow() -> MeetingOverlayPanel {
        if let window {
            MeetingLog.info("Reuse existing overlay panel")
            return window
        }

        MeetingLog.info("Create overlay panel")
        let panel = MeetingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        MeetingLog.info("Overlay panel configured level=popUpMenu behavior=canJoinAllSpaces+fullScreenAuxiliary+ignoresCycle nonactivating=true")
        self.window = panel
        return panel
    }

    private func preferredScreen() -> NSScreen? {
        if let keyScreen = window?.screen {
            return keyScreen
        }

        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return mouseScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    func windowDidBecomeKey(_ notification: Notification) {
        MeetingLog.info("Overlay panel became key")
    }

    func windowDidResignKey(_ notification: Notification) {
        MeetingLog.info("Overlay panel resigned key")
    }

    func windowWillClose(_ notification: Notification) {
        MeetingLog.info("Overlay panel will close")
        window = nil
    }

    private func targetFrame(
        for size: NSSize,
        window: MeetingOverlayPanel,
        screen: NSScreen?,
        centeredVertically: Bool
    ) -> NSRect {
        guard let screen else {
            return NSRect(origin: window.frame.origin, size: size)
        }

        if didPositionWindow, window.isVisible {
            let currentOrigin = clampedOrigin(for: window.frame.origin, size: size, screen: screen)
            return NSRect(origin: currentOrigin, size: size)
        }

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - size.width - 24
        let y = centeredVertically
            ? visibleFrame.midY - (size.height / 2)
            : visibleFrame.maxY - size.height - 24

        didPositionWindow = true
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func clampedOrigin(
        for origin: NSPoint,
        size: NSSize,
        screen: NSScreen
    ) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        let clampedX = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        let clampedY = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return NSPoint(x: clampedX, y: clampedY)
    }
}

final class MeetingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WindowDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct MeetingOverlayContainerView: View {
    @EnvironmentObject private var meetingSession: MeetingSessionController

    var body: some View {
        Group {
            switch meetingSession.overlayState {
            case .recordingBar:
                MeetingRecordingOverlayView()
            case .stopConfirmation:
                MeetingStopConfirmOverlayView()
            case .hidden:
                Color.clear
            }
        }
    }
}

private struct MeetingRecordingOverlayView: View {
    @EnvironmentObject private var meetingSession: MeetingSessionController
    @State private var isAnimatingIndicator = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(red: 0.74, green: 0.78, blue: 0.98), Color(red: 0.48, green: 0.68, blue: 0.98)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .padding(3)
                    )

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.31, green: 0.83, blue: 0.68), Color(red: 0.56, green: 0.86, blue: 0.38)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 15, height: 15)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 6, height: 6)
                        .scaleEffect(isAnimatingIndicator ? 1.18 : 0.72)
                        .opacity(isAnimatingIndicator ? 1 : 0.35)
                        .animation(
                            .easeInOut(duration: 0.62)
                                .repeatForever()
                                .delay(Double(index) * 0.12),
                            value: isAnimatingIndicator
                        )
                }
            }

            Text("记录中...")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 1, height: 18)

            Button {
                meetingSession.requestStopConfirmation()
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.36, blue: 0.31))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
            .buttonStyle(.plain)

            Button {
                meetingSession.reopenMainMeetingPage()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
        .padding(2)
        .onAppear {
            isAnimatingIndicator = true
        }
    }
}

private struct MeetingStopConfirmOverlayView: View {
    @EnvironmentObject private var meetingSession: MeetingSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.36, blue: 0.31))
                    .frame(width: 10, height: 10)
                    .opacity(0.95)

                Text(meetingSession.stopConfirmationReason == .timeLimitReached ? "已录满 1 小时，请结束会议" : "结束会议记录？")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()
            }

            Text(meetingSession.stopConfirmationReason == .timeLimitReached ? "会议录制最长支持 1 小时。请结束本次会议并开始生成记录。" : "结束后开始生成会议记录。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))

            HStack(spacing: 10) {
                Button {
                    Task { await meetingSession.finishMeetingRecording() }
                } label: {
                    Text("结束记录")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color(red: 0.08, green: 0.34, blue: 0.95), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    meetingSession.continueMeetingRecording()
                } label: {
                    Text("继续会议")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(meetingSession.stopConfirmationReason == .timeLimitReached)
                .opacity(meetingSession.stopConfirmationReason == .timeLimitReached ? 0.45 : 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(2)
    }
}
