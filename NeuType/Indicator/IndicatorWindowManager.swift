import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
class IndicatorWindowManager: NSObject, IndicatorViewDelegate, NSWindowDelegate {
    static let shared = IndicatorWindowManager()
    
    var window: NSWindow?
    var viewModel: IndicatorViewModel?
    private var isPositionEditing = false
    
    private override init() {
        super.init()
    }
    
    func show(nearPoint point: NSPoint? = nil, allowDragging: Bool = false) -> IndicatorViewModel {
        isPositionEditing = allowDragging
        RequestLogStore.log(.usage, "Indicator show requested allowDragging=\(allowDragging)")
        
        KeyboardShortcuts.enable(.escape)
        
        // Create new view model
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel
        
        if window == nil {
            // Create window if it doesn't exist - using NSPanel for full-screen compatibility
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = !allowDragging
            panel.isMovableByWindowBackground = allowDragging
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .utilityWindow
            panel.becomesKeyOnlyIfNeeded = true
            panel.delegate = self
            RequestLogStore.log(.usage, "Indicator panel created level=statusBar behavior=canJoinAllSpaces+fullScreenAuxiliary")
            
            self.window = panel
        } else {
            window?.ignoresMouseEvents = !allowDragging
            window?.isMovableByWindowBackground = allowDragging
        }
        
        // Position window using saved location, fallback to top-right
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        if let window = window, let screen = targetScreen {
            let windowFrame = window.frame
            let screenFrame = screen.frame

            let defaultX = screenFrame.maxX - windowFrame.width - 24
            let defaultY = screenFrame.maxY - windowFrame.height - 20
            let x = AppPreferences.shared.indicatorOriginX ?? defaultX
            let y = AppPreferences.shared.indicatorOriginY ?? defaultY
            
            // Adjust if out of screen bounds
            let clampedX = max(screenFrame.minX, min(x, screenFrame.maxX - windowFrame.width))
            let clampedY = max(screenFrame.minY, min(y, screenFrame.maxY - windowFrame.height))
            
            window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
            RequestLogStore.log(.usage, "Indicator frame origin=(\(Int(clampedX)), \(Int(clampedY))) screen=\(screen.localizedName)")
            
            // Set content view
            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
        }
        
        RequestLogStore.log(.usage, "Indicator frontmost app before show=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") activationPolicy=\(NSApp.activationPolicy().rawValue)")
        window?.orderFrontRegardless()
        if let window {
            RequestLogStore.log(.usage, "Indicator visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) windowNumber=\(window.windowNumber)")
        }
        return newViewModel
    }

    func showPositionEditor() {
        let vm = show(allowDragging: true)
        vm.state = .busy
        vm.customStatusText = "Drag to position"
    }
    
    func stopRecording() {
        viewModel?.startDecoding()
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }

    func hide() {
        RequestLogStore.log(.usage, "Indicator hide requested")
        KeyboardShortcuts.disable(.escape)
        
        Task {
            guard let viewModel = self.viewModel else { return }
            
            await viewModel.hideWithAnimation()
            viewModel.cleanup()
            
            self.window?.contentView = nil
            self.window?.orderOut(nil)
            self.window?.ignoresMouseEvents = true
            self.window?.isMovableByWindowBackground = false
            self.isPositionEditing = false
            self.viewModel = nil
            RequestLogStore.log(.usage, "Indicator hidden")
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard isPositionEditing, let origin = window?.frame.origin else { return }
        AppPreferences.shared.indicatorOriginX = origin.x
        AppPreferences.shared.indicatorOriginY = origin.y
    }
}
