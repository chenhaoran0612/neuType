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

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

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
        holdMode = false
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
            RequestLogStore.log(.usage, "Meeting shortcut keyDown")
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
        holdWorkItem?.cancel()
        holdMode = false
        RequestLogStore.log(.usage, "Hotkey keyDown")
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if self.activeVm == nil {
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
                RequestLogStore.log(.usage, "Recording started")
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                RequestLogStore.log(.usage, "Recording stopped by keyDown")
            }
        }
        
        if holdToRecordEnabled {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        RequestLogStore.log(.usage, "Hotkey keyUp")
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
                RequestLogStore.log(.usage, "Recording stopped on hold release")
            }
        }
    }
}
