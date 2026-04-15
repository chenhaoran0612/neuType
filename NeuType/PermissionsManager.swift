import AVFoundation
import AppKit
import Foundation
import CoreGraphics
import ScreenCaptureKit

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

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    @Published var isScreenRecordingPermissionGranted = false
    @Published var screenRecordingPermissionState: ScreenRecordingPermissionState = .needsAuthorization

    private var permissionCheckTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var isProbingScreenRecordingPermission = false
    private var lastScreenRecordingProbeAt: Date?

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
            self?.isAccessibilityPermissionGranted = granted
        }
    }

    func checkScreenRecordingPermission() {
        let granted: Bool
        if #available(macOS 10.15, *) {
            granted = CGPreflightScreenCaptureAccess()
        } else {
            granted = true
        }

        if granted {
            DispatchQueue.main.async { [weak self] in
                AppPreferences.shared.didPromptForScreenRecordingPermission = false
                AppPreferences.shared.screenRecordingPermissionPendingRelaunch = false
                self?.lastScreenRecordingProbeAt = nil
                self?.isScreenRecordingPermissionGranted = true
                self?.screenRecordingPermissionState = .granted
            }
            return
        }

        if #available(macOS 14.0, *) {
            let now = Date()
            if let lastProbeAt = lastScreenRecordingProbeAt,
               now.timeIntervalSince(lastProbeAt) < 2 {
                return
            }
            lastScreenRecordingProbeAt = now
            probeScreenRecordingPermission()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isScreenRecordingPermissionGranted = false
            self?.screenRecordingPermissionState = ScreenRecordingPermissionState.resolve(
                isGranted: false,
                requiresRelaunch: AppPreferences.shared.screenRecordingPermissionPendingRelaunch
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

    func requestScreenRecordingPermissionOrOpenSystemPreferences() {
        let requestAction: ScreenRecordingPermissionRequestAction

        if #available(macOS 10.15, *) {
            let preflightGranted = CGPreflightScreenCaptureAccess()
            let requestGranted: Bool?

            if !preflightGranted {
                AppPreferences.shared.didPromptForScreenRecordingPermission = true
                requestGranted = CGRequestScreenCaptureAccess()
                AppPreferences.shared.screenRecordingPermissionPendingRelaunch = requestGranted == true
            } else {
                isScreenRecordingPermissionGranted = true
                screenRecordingPermissionState = .granted
                AppPreferences.shared.screenRecordingPermissionPendingRelaunch = false
                requestGranted = nil
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

    private func probeScreenRecordingPermission() {
        guard !isProbingScreenRecordingPermission else { return }
        guard #available(macOS 14.0, *) else {
            DispatchQueue.main.async { [weak self] in
                self?.isScreenRecordingPermissionGranted = false
                self?.screenRecordingPermissionState = ScreenRecordingPermissionState.resolve(
                    isGranted: false,
                    requiresRelaunch: AppPreferences.shared.screenRecordingPermissionPendingRelaunch
                )
            }
            return
        }

        isProbingScreenRecordingPermission = true

        Task(priority: .utility) { [weak self] in
            let granted = await Self.canAccessScreenCaptureContent()
            guard let self else { return }
            await MainActor.run {
                self.isProbingScreenRecordingPermission = false

                if granted {
                    AppPreferences.shared.didPromptForScreenRecordingPermission = false
                    AppPreferences.shared.screenRecordingPermissionPendingRelaunch = false
                    self.lastScreenRecordingProbeAt = nil
                    self.isScreenRecordingPermissionGranted = true
                    self.screenRecordingPermissionState = .granted
                } else {
                    self.isScreenRecordingPermissionGranted = false
                    self.screenRecordingPermissionState = ScreenRecordingPermissionState.resolve(
                        isGranted: false,
                        requiresRelaunch: AppPreferences.shared.screenRecordingPermissionPendingRelaunch
                    )
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func canAccessScreenCaptureContent() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return !content.displays.isEmpty
        } catch {
            RequestLogStore.log(.usage, "Screen capture permission probe failed: \(error.localizedDescription)")
            return false
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
