import SwiftUI

@main
struct xerApp: App {
    @StateObject private var updateManager = UpdateManager()

    var body: some Scene {
        WindowGroup("xer") {
            ContentView()
                .environmentObject(updateManager)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1_360, height: 820)
        .windowResizability(.contentSize)
    }
}
