import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let toggleMeetingRecord = Self("toggleMeetingRecord", default: .init(.m, modifiers: [.option, .shift]))
    static let escape = Self("escape", default: .init(.escape))
}

struct MeetingShortcutValidator {
    let dictationShortcut: KeyboardShortcuts.Shortcut?

    func canUse(_ shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let shortcut else { return true }
        guard let dictationShortcut else { return true }
        return shortcut != dictationShortcut
    }
}

class ShortcutManager {
    static let shared = ShortcutManager()

    enum HotkeyAction: Equatable {
        case none
        case startRecording
        case stopRecording

        static func resolveOnKeyDown(hasActiveIndicator: Bool) -> Self {
            hasActiveIndicator ? .none : .startRecording
        }

        static func resolveOnKeyUp(hasActiveIndicator: Bool) -> Self {
            hasActiveIndicator ? .stopRecording : .none
        }
    }

    private var activeVm: IndicatorViewModel?

    private init() {
        RequestLogStore.log(.usage, "ShortcutManager initialized")
        
        setupKeyboardShortcuts()
        setupModifierKeyMonitor()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        RequestLogStore.log(.usage, "Indicator hidden")
        activeVm = nil
    }
    
    @objc private func hotkeySettingsChanged() {
        RequestLogStore.log(.usage, "Hotkey settings changed")
        setupModifierKeyMonitor()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                if self?.activeVm != nil {
                    RequestLogStore.log(.usage, "Escape pressed -> force stop")
                    IndicatorWindowManager.shared.stopForce()
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)

        KeyboardShortcuts.onKeyDown(for: .toggleMeetingRecord) {
            Task { @MainActor in
                let shortcutDescription = KeyboardShortcuts.Shortcut(name: .toggleMeetingRecord)?.description ?? "unconfigured"
                RequestLogStore.log(.usage, "Meeting shortcut keyDown: \(shortcutDescription)")
                NotificationCenter.default.post(name: .toggleMeetingMinutesShortcut, object: nil)
            }
        }
    }
    
    private func setupModifierKeyMonitor() {
        let modifierKeyString = AppPreferences.shared.modifierOnlyHotkey
        let modifierKey = ModifierKey(rawValue: modifierKeyString) ?? .leftControl

        KeyboardShortcuts.disable(.toggleRecord)

        ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
            self?.handleKeyDown()
        }

        ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
            self?.handleKeyUp()
        }

        ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
        RequestLogStore.log(.usage, "Modifier-only hotkey active: \(modifierKey.displayName)")
    }
    
    private func handleKeyDown() {
        let mainWindow = NSApplication.shared.windows.first
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        RequestLogStore.log(
            .usage,
            "Hotkey keyDown frontmostApp=\(frontmostApp) appActive=\(NSApp.isActive) mainWindowVisible=\(mainWindow?.isVisible ?? false) mainWindowMiniaturized=\(mainWindow?.isMiniaturized ?? false) activeIndicator=\(activeVm != nil)"
        )

        Task { @MainActor in
            switch HotkeyAction.resolveOnKeyDown(hasActiveIndicator: self.activeVm != nil) {
            case .startRecording:
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                let indicatorPoint: NSPoint?
                if let caret = FocusUtils.getCaretRect() {
                    indicatorPoint = FocusUtils.convertAXPointToCocoa(caret.origin)
                } else {
                    indicatorPoint = cursorPosition
                }
                let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                vm.startRecording()
                self.activeVm = vm
                RequestLogStore.log(.usage, "Recording started indicatorCreated=true")
            case .stopRecording:
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                RequestLogStore.log(.usage, "Recording stopped by keyDown")
            case .none:
                break
            }
        }
    }
    
    private func handleKeyUp() {
        RequestLogStore.log(.usage, "Hotkey keyUp")

        Task { @MainActor in
            switch HotkeyAction.resolveOnKeyUp(hasActiveIndicator: self.activeVm != nil) {
            case .stopRecording:
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                RequestLogStore.log(.usage, "Recording stopped on hold release")
            case .startRecording, .none:
                break
            }
        }
    }
}
