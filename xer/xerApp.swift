import SwiftUI

@main
struct xerApp: App {
    var body: some Scene {
        WindowGroup("xer") {
            ContentView()
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1_360, height: 820)
        .windowResizability(.contentSize)
    }
}
