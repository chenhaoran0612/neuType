import AVFoundation
import AppKit
import Foundation
import CoreGraphics

enum Permission {
    case microphone
    case accessibility
    case screenRecording
}

enum ScreenRecordingPermissionState: Equatable {
    case granted
    case needsAuthorization
    case needsRelaunch

    static func resolve(isGranted: Bool, requiresRelaunch: Bool) -> Self {
        if isGranted {
            return .granted
        }

        return requiresRelaunch ? .needsRelaunch : .needsAuthorization
    }
}

enum ScreenRecordingPermissionRequestAction: Equatable {
    case granted
    case openSystemPreferences
    case relaunch

    static func resolve(preflightGranted: Bool, requestGranted: Bool?) -> Self {
        if preflightGranted {
            return .granted
        }

        if requestGranted == true {
            return .relaunch
        }

        return .openSystemPreferences
    }
}

enum AccessibilityPermissionState: Equatable {
    case granted
    case needsAuthorization
    case needsRelaunch

    static func resolve(isGranted: Bool, requiresRelaunch: Bool) -> Self {
        if isGranted {
            return .granted
        }

        return requiresRelaunch ? .needsRelaunch : .needsAuthorization
    }
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    @Published var isScreenRecordingPermissionGranted = false
    @Published var accessibilityPermissionState: AccessibilityPermissionState = .needsAuthorization
    @Published var screenRecordingPermissionState: ScreenRecordingPermissionState = .needsAuthorization

    private var permissionCheckTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []

    init() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
        checkScreenRecordingPermission()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityPermissionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        setupWindowObservers()
    }

    deinit {
        stopPermissionChecking()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupWindowObservers() {
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPermissionChecking()
        }

        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
        }

        let appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkMicrophonePermission()
            self?.checkAccessibilityPermission()
            self?.checkScreenRecordingPermission()
            self?.startPermissionChecking()
        }

        windowObservers = [showObserver, closeObserver, appActiveObserver]

        startPermissionChecking()
    }

    private func startPermissionChecking() {
        guard permissionCheckTimer == nil else { return }
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkMicrophonePermission()
            self?.checkAccessibilityPermission()
            self?.checkScreenRecordingPermission()
        }
    }

    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        DispatchQueue.main.async { [weak self] in
            switch status {
            case .authorized:
                self?.isMicrophonePermissionGranted = true
            default:
                self?.isMicrophonePermissionGranted = false
            }
        }
    }

    func checkAccessibilityPermission() {
        let granted = AXIsProcessTrusted()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAccessibilityPermissionGranted = granted
            self.accessibilityPermissionState = AccessibilityPermissionState.resolve(
                isGranted: granted,
                requiresRelaunch: false
            )
        }
    }

    func checkScreenRecordingPermission() {
        let preflightGranted: Bool
        if #available(macOS 10.15, *) {
            preflightGranted = CGPreflightScreenCaptureAccess()
        } else {
            preflightGranted = true
        }

        let requiresRelaunch = AppPreferences.shared.screenRecordingPermissionPendingRelaunch
        RequestLogStore.log(
            .usage,
            "Screen recording preflight granted=\(preflightGranted) pendingRelaunch=\(requiresRelaunch)"
        )

        if preflightGranted {
            DispatchQueue.main.async { [weak self] in
                AppPreferences.shared.didPromptForScreenRecordingPermission = false
                AppPreferences.shared.screenRecordingPermissionPendingRelaunch = false
                self?.isScreenRecordingPermissionGranted = true
                self?.screenRecordingPermissionState = .granted
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isScreenRecordingPermissionGranted = false
            self?.screenRecordingPermissionState = ScreenRecordingPermissionState.resolve(
                isGranted: false,
                requiresRelaunch: requiresRelaunch
            )
        }
    }

    func requestMicrophonePermissionOrOpenSystemPreferences() {

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophonePermissionGranted = granted
                }
            }
        case .authorized:
            self.isMicrophonePermissionGranted = true
        default:
            openSystemPreferences(for: .microphone)
        }
    }

    func requestAccessibilityPermissionOrOpenSystemPreferences() {
        let granted = AXIsProcessTrusted()

        if granted {
            isAccessibilityPermissionGranted = true
            accessibilityPermissionState = .granted
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSystemPreferences(for: .accessibility)
        checkAccessibilityPermission()
    }

    func requestScreenRecordingPermissionOrOpenSystemPreferences() {
        let requestAction: ScreenRecordingPermissionRequestAction

        if #available(macOS 10.15, *) {
            let preflightGranted = CGPreflightScreenCaptureAccess()
            let requestGranted: Bool?

            if preflightGranted {
                isScreenRecordingPermissionGranted = true
                screenRecordingPermissionState = .granted
                AppPreferences.shared.screenRecordingPermissionPendingRelaunch = false
                requestGranted = nil
            } else if AppPreferences.shared.screenRecordingPermissionPendingRelaunch {
                isScreenRecordingPermissionGranted = false
                screenRecordingPermissionState = .needsRelaunch
                requestGranted = true
            } else {
                AppPreferences.shared.didPromptForScreenRecordingPermission = true
                requestGranted = CGRequestScreenCaptureAccess()
                AppPreferences.shared.screenRecordingPermissionPendingRelaunch = requestGranted == true
            }

            requestAction = ScreenRecordingPermissionRequestAction.resolve(
                preflightGranted: preflightGranted,
                requestGranted: requestGranted
            )
        } else {
            isScreenRecordingPermissionGranted = true
            screenRecordingPermissionState = .granted
            requestAction = .granted
        }

        checkScreenRecordingPermission()

        switch requestAction {
        case .granted:
            return
        case .openSystemPreferences:
            openSystemPreferences(for: .screenRecording)
        case .relaunch:
            relaunchApplication()
        }
    }

    func relaunchApplication() {
        AppRelauncher.relaunch(reason: "permissions manager")
    }

    @objc private func accessibilityPermissionChanged() {
        checkAccessibilityPermission()
    }

    func openSystemPreferences(for permission: Permission) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
