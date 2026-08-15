import AppKit
import SwiftUI

// THESIS: xer is a compact native command center: configure left, target right, inspect below—never a stacked form.
// OWN-WORLD: A stable translucent project rail, precise split panes, pearl surfaces, and one disciplined indigo action.
// STORY: Choose trusted source code, confirm its scheme and ready devices, then watch one observable multi-device operation unfold.
// FIRST VIEWPORT: Projects anchor the left; build setup and destinations share the upper canvas; the console spans the lower canvas.
// FORM: Operate-mode project rail plus horizontal configuration split and a vertically resizable console, following the approved concept.

struct ContentView: View {
    @StateObject var model = AppModel()
    @EnvironmentObject var updateManager: UpdateManager
    @Environment(\.colorScheme) var colorScheme
    @State var trustCandidateID: String?
    @State var projectQuery = ""
    @State var logQuery = ""
    @State var logFilter: LogFilter = .all
    @State var autoScrollConsole = true
    @State var removalCandidate: SidebarRemovalCandidate?
    @State var destinationLayout: DestinationLayout = .grid
    @State var destinationScope: DestinationScope = .all
    @State var selectedDestinationOS: Set<String> = []
    @State var readyDestinationsOnly = false
    @State var consoleResizeStart: Double?
    @State var consoleDragHeight: Double?
    @AppStorage("xer.consoleHeight") var consoleHeight = 390.0
    @AppStorage("xer.favoriteDestinationIDs") var favoriteDestinationStorage = ""
    @FocusState var isLogSearchFocused: Bool
    @FocusState var isDestinationSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(250)
        } detail: {
            detailPane
        }
        .tint(XerTheme.action)
        .frame(minWidth: 760, minHeight: 560)
        .onKeyPress(characters: CharacterSet(charactersIn: "f"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.modifiers.contains(.option) {
                isDestinationSearchFocused = true
            } else {
                isLogSearchFocused = true
            }
            return .handled
        }
        .task {
            model.restorePersistedProjects()
            if model.destinations.isEmpty {
                model.refreshDestinations()
            }
            updateManager.checkForUpdatesInBackground()
        }
        .sheet(
            isPresented: Binding(
                get: { model.lastIssue != nil },
                set: { isPresented in
                    if !isPresented { model.clearError() }
                }
            )
        ) {
            if let issue = model.lastIssue {
                OperationIssueSheet(issue: issue) {
                    model.clearError()
                }
            }
        }
        .confirmationDialog(
            "Trust imported project?",
            isPresented: Binding(
                get: { trustCandidateID != nil },
                set: { isPresented in
                    if !isPresented { trustCandidateID = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let trustCandidateID,
               let project = model.projects.first(where: { $0.id == trustCandidateID }) {
                Button("Trust and Enable Builds for \(project.displayName)") {
                    model.trustProject(project.id)
                    self.trustCandidateID = nil
                }
            }
            Button("Cancel", role: .cancel) { trustCandidateID = nil }
        } message: {
            Text("Xcode builds can execute scripts and package build tools included in this project. Trust only code you recognize. You can revoke trust at any time.")
        }
        .alert(
            removalCandidate?.title ?? "Remove?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { removalCandidate = nil }
            Button("Remove", role: .destructive) {
                guard let removalCandidate else { return }
                switch removalCandidate {
                case .project(let project):
                    model.removeProject(project.id)
                case .folder(let path, _, _):
                    model.removeImportedFolder(path)
                }
                self.removalCandidate = nil
            }
        } message: {
            Text(removalCandidate?.message ?? "No files on disk are deleted.")
        }
    }
}
