import SwiftUI

@main
struct xerApp: App {
    @NSApplicationDelegateAdaptor(XerAppDelegate.self) private var appDelegate
    @StateObject private var updateManager = UpdateManager()
    @StateObject private var cliRequestRouter = CLIRequestRouter()

    var body: some Scene {
        let _ = Self.configure(appDelegate: appDelegate, router: cliRequestRouter)
        return WindowGroup("xer") {
            ContentView()
                .environmentObject(updateManager)
                .environmentObject(cliRequestRouter)
                .onOpenURL { url in
                    guard let request = CLIRouteParser.request(from: url) else { return }
                    cliRequestRouter.deliver(request)
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1_360, height: 820)
        .windowResizability(.contentSize)
    }

    private static func configure(appDelegate: XerAppDelegate, router: CLIRequestRouter) -> Bool {
        appDelegate.cliRequestRouter = router
        return true
    }
}
