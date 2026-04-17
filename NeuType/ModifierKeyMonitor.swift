import AppKit
import Carbon
import Foundation

enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case fn = "fn"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "None"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "Fn"
        }
    }
    
    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .leftCommand: return "⌘"
        case .rightCommand: return "⌘"
        case .leftOption: return "⌥"
        case .rightOption: return "⌥"
        case .leftShift: return "⇧"
        case .rightShift: return "⇧"
        case .leftControl: return "⌃"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
    
    var keyCode: UInt16 {
        switch self {
        case .none: return 0
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .fn: return .function
        }
    }
    
    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }

    func matchesFlagsChangedEvent(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch self {
        case .none:
            return false
        case .fn:
            return keyCode == self.keyCode || flags.contains(.maskSecondaryFn)
        default:
            return keyCode == self.keyCode
        }
    }

    func shouldProcessFlagsChangedEvent(
        keyCode: UInt16,
        flags: CGEventFlags,
        wasPressed: Bool
    ) -> Bool {
        switch self {
        case .none:
            return false
        case .fn:
            return wasPressed || keyCode == self.keyCode || flags.contains(.maskSecondaryFn)
        default:
            return matchesFlagsChangedEvent(keyCode: keyCode, flags: flags)
        }
    }

    func matchesFlagsChangedEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .none:
            return false
        case .fn:
            return keyCode == self.keyCode || flags.contains(.function)
        default:
            return keyCode == self.keyCode
        }
    }

    func shouldProcessFlagsChangedEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        wasPressed: Bool
    ) -> Bool {
        switch self {
        case .none:
            return false
        case .fn:
            return wasPressed || keyCode == self.keyCode || flags.contains(.function)
        default:
            return matchesFlagsChangedEvent(keyCode: keyCode, flags: flags)
        }
    }
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}

class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnReleasePollingTimer: Timer?
    private var selectedModifierKey: ModifierKey = .none
    private var isModifierPressed = false
    
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    
    private init() {}
    
    func start(modifierKey: ModifierKey) {
        guard modifierKey != .none else {
            stop()
            return
        }
        
        stop()
        
        selectedModifierKey = modifierKey
        isModifierPressed = false
        
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        
        let tapLocation: CGEventTapLocation = modifierKey == .fn ? .cghidEventTap : .cgSessionEventTap

        guard let tap = CGEvent.tapCreate(
            tap: tapLocation,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                
                let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                
                monitor.handleFlagsChanged(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("ModifierKeyMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Started monitoring for \(modifierKey.displayName) via \(tapLocation == .cghidEventTap ? "HID" : "session") tap")
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
            return event
        }
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        stopFnReleasePolling()
        isModifierPressed = false
        print("ModifierKeyMonitor: Stopped")
    }
    
    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Re-enabled tap after timeout")
        }
    }
    
    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        guard selectedModifierKey.shouldProcessFlagsChangedEvent(
            keyCode: keyCode,
            flags: flags,
            wasPressed: isModifierPressed
        ) else { return }
        
        let cgFlag = selectedModifierKey.cgEventFlag
        let isPressed = flags.contains(cgFlag)
        
        if isPressed && !isModifierPressed {
            isModifierPressed = true
            startFnReleasePollingIfNeeded()
            DispatchQueue.main.async {
                RequestLogStore.log(.usage, "Modifier monitor keyDown via CGEvent: \(self.selectedModifierKey.displayName)")
                self.onKeyDown?()
            }
        } else if !isPressed && isModifierPressed {
            isModifierPressed = false
            stopFnReleasePolling()
            DispatchQueue.main.async {
                RequestLogStore.log(.usage, "Modifier monitor keyUp via CGEvent: \(self.selectedModifierKey.displayName)")
                self.onKeyUp?()
            }
        }
    }

    private func handleFlagsChanged(event: NSEvent) {
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control, .function])

        guard selectedModifierKey.shouldProcessFlagsChangedEvent(
            keyCode: keyCode,
            flags: flags,
            wasPressed: isModifierPressed
        ) else { return }

        let isPressed = flags.contains(selectedModifierKey.modifierFlag)

        if isPressed && !isModifierPressed {
            isModifierPressed = true
            startFnReleasePollingIfNeeded()
            RequestLogStore.log(.usage, "Modifier monitor keyDown via NSEvent: \(selectedModifierKey.displayName)")
            onKeyDown?()
        } else if !isPressed && isModifierPressed {
            isModifierPressed = false
            stopFnReleasePolling()
            RequestLogStore.log(.usage, "Modifier monitor keyUp via NSEvent: \(selectedModifierKey.displayName)")
            onKeyUp?()
        }
    }

    private func startFnReleasePollingIfNeeded() {
        guard selectedModifierKey == .fn else { return }

        DispatchQueue.main.async {
            self.fnReleasePollingTimer?.invalidate()
            self.fnReleasePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                guard self.isModifierPressed, !flags.contains(.maskSecondaryFn) else { return }

                self.isModifierPressed = false
                self.stopFnReleasePolling()
                RequestLogStore.log(.usage, "Modifier monitor keyUp via polling: \(self.selectedModifierKey.displayName)")
                self.onKeyUp?()
            }
        }
    }

    private func stopFnReleasePolling() {
        DispatchQueue.main.async {
            self.fnReleasePollingTimer?.invalidate()
            self.fnReleasePollingTimer = nil
        }
    }
    
    deinit {
        stop()
    }
}
