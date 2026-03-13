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
            panel.delegate = self
            
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
            
            // Set content view
            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
        }
        
        window?.orderFront(nil)
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
