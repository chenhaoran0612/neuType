import AppKit
import Foundation

enum AppRelauncher {
    static func relaunch(reason: String) {
        let applicationURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        RequestLogStore.log(.usage, "App relaunch requested: \(reason)")

        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            if let error {
                RequestLogStore.log(.usage, "App relaunch failed: \(error.localizedDescription)")
                return
            }

            RequestLogStore.log(.usage, "App relaunch launch request succeeded")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
