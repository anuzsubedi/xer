import AppKit
import SwiftUI

final class XerAppDelegate: NSObject, NSApplicationDelegate {
    var cliRequestRouter: CLIRequestRouter?
    private var suppressForegroundActivation = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              let request = CLIRouteParser.request(from: url) else {
            return
        }
        if request.bringsApplicationToFront {
            activateExistingWindow(in: application)
        } else {
            suppressForegroundActivation = true
        }
        Task { @MainActor in
            self.cliRequestRouter?.deliver(request)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if suppressForegroundActivation {
            suppressForegroundActivation = false
            return false
        }
        activateExistingWindow(in: sender)
        return false
    }

    @discardableResult
    private func activateExistingWindow(in application: NSApplication) -> Bool {
        guard let window = application.windows.first(where: \.canBecomeKey)
                ?? application.windows.first else {
            return false
        }
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
