import AppKit
import SwiftUI

final class XerAppDelegate: NSObject, NSApplicationDelegate {
    var cliRequestRouter: CLIRequestRouter?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              let request = CLIRouteParser.request(from: url) else {
            return
        }
        Task { @MainActor in
            cliRequestRouter?.deliver(request)
        }
    }
}
