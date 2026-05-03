import AppKit
import Foundation

@MainActor
final class LiveMeetingCaptionShortcutCoordinator {
    static let shared = LiveMeetingCaptionShortcutCoordinator()

    private init() {}

    func toggle(
        viewModel: RealTimeMeetingCaptionViewModel = .shared,
        minimizeMainWindowOnStart: Bool = true
    ) async {
        if viewModel.isRunning {
            await viewModel.stop()
            RequestLogStore.log(.usage, "Live captions toggle stopped session")
            return
        }

        await viewModel.start()

        guard viewModel.isRunning else {
            RequestLogStore.log(.usage, "Live captions toggle start did not enter running state: \(viewModel.state)")
            return
        }

        FloatingLiveMeetingCaptionWindowManager.shared.show(viewModel: viewModel, activate: false)

        if minimizeMainWindowOnStart {
            minimizeMainWindow()
        }
    }

    func minimizeMainWindow() {
        guard let window = mainApplicationWindow() else {
            RequestLogStore.log(.usage, "Live captions requested main window minimize but no eligible window was found")
            return
        }

        guard window.isVisible, !window.isMiniaturized else { return }
        window.miniaturize(nil)
        RequestLogStore.log(.usage, "Live captions minimized main window after start")
    }

    private func mainApplicationWindow() -> NSWindow? {
        NSApplication.shared.windows.first { window in
            guard !(window is NSPanel) else { return false }
            guard window.contentView != nil else { return false }
            return window.canBecomeMain || window.canBecomeKey
        }
    }
}
