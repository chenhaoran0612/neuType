import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()
    
    var window: NSWindow?
    var viewModel: IndicatorViewModel?
    
    private init() {}
    
    func show(nearPoint point: NSPoint? = nil) -> IndicatorViewModel {
        
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
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            
            self.window = panel
        }
        
        // Position window at top-right of screen
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        if let window = window, let screen = targetScreen {
            let windowFrame = window.frame
            let screenFrame = screen.frame

            let x = screenFrame.maxX - windowFrame.width - 24
            let y = screenFrame.maxY - windowFrame.height - 24
            
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
            self.viewModel = nil
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        hide()
    }
}
