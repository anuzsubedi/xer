import AppKit
import SwiftUI

// THESIS: xer is a compact native command center: configure left, target right, inspect below—never a stacked form.
// OWN-WORLD: A stable translucent project rail, precise split panes, pearl surfaces, and one disciplined indigo action.
// STORY: Choose trusted source code, confirm its scheme and ready devices, then watch one observable multi-device operation unfold.
// FIRST VIEWPORT: Projects anchor the left; build setup and destinations share the upper canvas; the console spans the lower canvas.
// FORM: Operate-mode project rail plus horizontal configuration split and a vertically resizable console, following the approved concept.

private enum XerTheme {
    static let action = Color(red: 0.196, green: 0.392, blue: 0.910)
    static let workspace = Color(nsColor: .windowBackgroundColor)
    static let inspector = Color(nsColor: .textBackgroundColor)
}

private enum SidebarRemovalCandidate: Identifiable {
    case project(ImportedProject)
    case folder(path: String, name: String, projectCount: Int)

    var id: String {
        switch self {
        case .project(let project): "project:\(project.id)"
        case .folder(let path, _, _): "folder:\(path)"
        }
    }

    var title: String {
        switch self {
        case .project: "Remove Project?"
        case .folder: "Remove Imported Folder?"
        }
    }

    var message: String {
        switch self {
        case .project(let project):
            "This removes \(project.displayName) from xer. Files on disk are not deleted."
        case .folder(_, let name, let projectCount):
            "This removes \(name) and its \(projectCount) project record(s) from xer. Files on disk are not deleted."
        }
    }
}

private struct SidebarProjectGroup: Identifiable {
    let folderPath: String
    let projects: [ImportedProject]
    let totalProjectCount: Int

    var id: String { folderPath }
    var displayName: String {
        URL(fileURLWithPath: folderPath, isDirectory: true).lastPathComponent
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var trustCandidateID: String?
    @State private var projectQuery = ""
    @State private var logQuery = ""
    @State private var logFilter: LogFilter = .all
    @State private var autoScrollConsole = true
    @State private var removalCandidate: SidebarRemovalCandidate?
    @State private var destinationLayout: DestinationLayout = .grid
    @State private var destinationScope: DestinationScope = .all
    @State private var selectedDestinationOS: Set<String> = []
    @State private var readyDestinationsOnly = false
    @State private var consoleResizeStart: Double?
    @State private var consoleDragHeight: Double?
    @AppStorage("xer.consoleHeight") private var consoleHeight = 390.0
    @AppStorage("xer.favoriteDestinationIDs") private var favoriteDestinationStorage = ""
    @FocusState private var isLogSearchFocused: Bool
    @FocusState private var isDestinationSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(250)
        } detail: {
            detailPane
        }
        .tint(XerTheme.action)
        .frame(minWidth: 760, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.refreshDestinations()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isBusy)

                if model.isBusy {
                    Button {
                        model.cancelCurrentOperation()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                    .help("Stop the current build, install, launch, or console stream (⌘.)")
                    .accessibilityLabel("Stop current operation")
                }

                OperationStatus(state: model.operationState, isBusy: model.isBusy)
            }
        }
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
        }
        .alert(
            "Operation Issue",
            isPresented: Binding(
                get: { model.lastErrorMessage != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    DispatchQueue.main.async {
                        model.clearError()
                    }
                }
            )
        ) {
            Button("Dismiss") { model.clearError() }
        } message: {
            Text(model.lastErrorMessage ?? "The operation could not be completed.")
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

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("PROJECTS")
                        Spacer()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                    if model.projects.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No projects yet")
                                .font(.headline)
                            Text("Import a parent folder to discover .xcworkspace and .xcodeproj containers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Choose Folder…") {
                                model.chooseAndImportParentFolder()
                            }
                            .disabled(model.isBusy)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 28)
                    } else {
                        ForEach(filteredProjectGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(group.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Button {
                                        removalCandidate = .folder(
                                            path: group.folderPath,
                                            name: group.displayName,
                                            projectCount: group.totalProjectCount
                                        )
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove imported folder from xer")
                                    .accessibilityLabel("Remove imported folder \(group.displayName)")
                                    .disabled(model.isBusy)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)

                                ForEach(group.projects) { project in
                                    Button {
                                        guard project.id != model.selectedProjectID else { return }
                                        model.selectProject(project.id)
                                    } label: {
                                        ProjectRow(project: project, icon: model.projectIcon(for: project))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(
                                                project.id == model.selectedProjectID
                                                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
                                                    : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            removalCandidate = .project(project)
                                        } label: {
                                            Label("Remove Project…", systemImage: "trash")
                                        }
                                        Button(role: .destructive) {
                                            removalCandidate = .folder(
                                                path: group.folderPath,
                                                name: group.displayName,
                                                projectCount: group.totalProjectCount
                                            )
                                        } label: {
                                            Label("Remove Imported Folder…", systemImage: "folder.badge.minus")
                                        }
                                    }
                                    .accessibilityAddTraits(project.id == model.selectedProjectID ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)

            Divider()

            HStack(spacing: 10) {
                Button {
                    model.chooseAndImportParentFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("o", modifiers: [.command])
                .help("Import a folder containing Xcode workspaces or projects (⌘O)")
                .accessibilityLabel("Import project folder")
                .disabled(model.isBusy)

                Button {
                    if let project = model.selectedProject {
                        removalCandidate = .project(project)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.isBusy || model.selectedProject == nil)
                .accessibilityLabel("Remove project")

                sidebarSearchField
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let project = model.selectedProject {
            GeometryReader { proxy in
                let usesSplitWorkspace = proxy.size.width >= 840
                let minimumWorkspaceHeight = usesSplitWorkspace ? 300.0 : 280.0
                let maximumConsoleHeight = max(190.0, Double(proxy.size.height) - minimumWorkspaceHeight - 5)
                let requestedConsoleHeight = consoleDragHeight ?? consoleHeight
                let resolvedConsoleHeight = min(max(requestedConsoleHeight, 190.0), maximumConsoleHeight)

                VStack(spacing: 0) {
                    Group {
                        if usesSplitWorkspace { wideWorkspace(project) }
                        else { compactWorkspace(project) }
                    }
                    .frame(height: proxy.size.height - CGFloat(resolvedConsoleHeight) - 5)

                    consoleDivider(
                        currentHeight: resolvedConsoleHeight,
                        maximumHeight: maximumConsoleHeight
                    )

                    logConsole
                        .frame(height: CGFloat(resolvedConsoleHeight))
                }
                .background(XerTheme.workspace)
            }
        } else {
            emptyWorkspace
        }
    }

    private func wideWorkspace(_ project: ImportedProject) -> some View {
        GeometryReader { proxy in
            let configurationWidth = min(450, max(360, proxy.size.width * 0.40))

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let error = model.lastErrorMessage {
                            issueBanner(error)
                        }
                        routeSection(project)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: configurationWidth)
                .background(XerTheme.workspace)

                Divider()

                VStack(spacing: 0) {
                    ScrollView {
                        destinationsSection
                            .padding(24)
                    }
                    Divider()
                    commandBar
                }
                .frame(maxWidth: .infinity)
                .background(XerTheme.workspace)
            }
        }
    }

    private func compactWorkspace(_ project: ImportedProject) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let error = model.lastErrorMessage {
                        issueBanner(error)
                    }
                    routeSection(project)
                    Divider()
                    destinationsSection
                }
                .padding(responsivePanePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            commandBar
        }
        .background(XerTheme.workspace)
    }

    private var responsivePanePadding: CGFloat { 18 }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("Choose a project", systemImage: "hammer")
        } description: {
            Text("Select a discovered project in the sidebar, or import a folder to begin.")
        } actions: {
            Button("Import Folder…") {
                model.chooseAndImportParentFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model.isBusy)
        }
    }

    private func routeSection(_ project: ImportedProject) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scheme")
                    .font(.headline)
                routeScheme(project)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Build Configuration")
                    .font(.headline)
                FullWidthMenuControl(
                    title: model.buildConfiguration,
                    systemImage: "hammer"
                ) {
                    Button("Debug") { model.selectBuildConfiguration("Debug") }
                    Button("Release") { model.selectBuildConfiguration("Release") }
                }
                .disabled(model.isBusy)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Actions")
                    .font(.headline)

                HStack(spacing: 2) {
                    actionSegment(
                        "Build",
                        isEnabled: model.canBuild,
                        action: model.buildSelected
                    )
                    actionSegment(
                        "Install",
                        isEnabled: model.canInstall,
                        action: model.installSelected
                    )
                    actionSegment(
                        "Build & Run",
                        isProminent: true,
                        isEnabled: !model.isBusy,
                        action: model.buildInstallAndLaunchSelected
                    )
                }
                .padding(2)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Options")
                    .font(.headline)
                Toggle("Clean build folder before building", isOn: $model.cleanBuildFolder)
                Toggle("Stream standard output and print()", isOn: $model.openConsoleForOutput)
                Toggle("Include Logger and OSLog messages", isOn: $model.includeUnifiedLogs)
                Toggle("Automatically select running destination", isOn: $model.automaticallySelectRunningDestination)
            }
            .toggleStyle(.checkbox)
            .disabled(model.isBusy)

            if !project.isTrusted {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Trust required before building")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Review & Trust…") {
                        trustCandidateID = project.id
                    }
                    .disabled(model.isBusy)
                }
            } else if project.schemes.isEmpty {
                Label("No shared scheme was found. Share a scheme in Xcode, then refresh.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func actionSegment(
        _ title: String,
        isProminent: Bool = false,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isProminent ? .semibold : .regular))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
                .background(
                    isProminent ? XerTheme.action : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func routeScheme(_ project: ImportedProject) -> some View {
        if project.schemes.isEmpty {
            Text("No shared schemes")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        } else {
            FullWidthMenuControl(
                title: model.selectedSchemeName ?? "Choose Scheme",
                systemImage: "shippingbox"
            ) {
                ForEach(project.schemes) { scheme in
                    Button(scheme.name) {
                        model.selectScheme(scheme.name)
                    }
                }
            }
            .accessibilityLabel("Build scheme")
            .disabled(model.isBusy)
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    destinationSectionHeading
                    Spacer()
                    destinationSelectionStatus
                }

                VStack(alignment: .leading, spacing: 8) {
                    destinationSectionHeading
                    destinationSelectionStatus
                }
            }

            HStack(spacing: 8) {
                DestinationSearchField(
                    text: Binding(
                        get: { model.destinationSearchQuery },
                        set: { query in
                            guard query != model.destinationSearchQuery else { return }
                            DispatchQueue.main.async {
                                model.setDestinationSearchQuery(query)
                            }
                        }
                    ),
                    isFocused: $isDestinationSearchFocused
                )

                Picker("Destination layout", selection: $destinationLayout) {
                    Label("List", systemImage: "list.bullet").tag(DestinationLayout.list)
                    Label("Grid", systemImage: "square.grid.2x2").tag(DestinationLayout.grid)
                }
                .labelsHidden()
                .labelStyle(.iconOnly)
                .pickerStyle(.segmented)
                .frame(width: 84)
            }

            ViewThatFits(in: .horizontal) {
                destinationFilterBar(compact: false)
                destinationFilterBar(compact: true)
            }

            if let warning = model.destinationWarning {
                developerToolsCallout(warning)
            }

            if model.isBusy && model.operationState == .refreshingDestinations && model.destinations.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checking developer destinations…")
                            .font(.callout.weight(.medium))
                        Text("Reading Simulator and CoreDevice availability from Xcode tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 20)
            } else if model.destinations.isEmpty {
                ContentUnavailableView {
                    Label("No destinations available", systemImage: "iphone.slash")
                } description: {
                    Text("Open a simulator, or connect, pair, and enable Developer Mode on a physical device. Then refresh destinations.")
                } actions: {
                    Button("Refresh Destinations") { model.refreshDestinations() }
                        .disabled(model.isBusy)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if visibleDestinations.isEmpty {
                ContentUnavailableView {
                    Label("No matching destinations", systemImage: "magnifyingglass")
                } description: {
                    Text(destinationEmptyDescription)
                } actions: {
                    Button("Clear Filters") {
                        clearDestinationFilters(includeSearch: true)
                        isDestinationSearchFocused = true
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(destinationPresentationGroups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider()
                        }
                        destinationGroup(
                            title: group.title,
                            kind: group.kind,
                            destinations: group.destinations
                        )
                    }
                }
            }
        }
    }

    private var destinationSectionHeading: some View {
        sectionHeading(
            "Destinations",
            detail: "Choose the ready devices that should receive this build. Up to two run in parallel."
        )
    }

    private var destinationSelectionStatus: some View {
        HStack(spacing: 8) {
            if model.isBusy && model.operationState == .refreshingDestinations && !model.destinations.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing destinations")
            }
            Text("\(model.selectedDestinations.count) selected")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.selectedDestinations.isEmpty ? .secondary : XerTheme.action)
        }
    }

    private func destinationFilterBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            destinationScopeButton(.all, compact: compact)
            destinationScopeButton(.favorites, compact: compact)
            destinationScopeButton(.physical, compact: compact)
            destinationScopeButton(.simulators, compact: compact)
            destinationMoreFiltersMenu(compact: compact)

            Spacer(minLength: 4)

            ForEach(Array(selectedDestinationOS.sorted().prefix(compact ? 1 : 2)), id: \.self) { os in
                DestinationFilterToken(title: os) {
                    selectedDestinationOS.remove(os)
                }
            }

            if selectedDestinationOS.count > (compact ? 1 : 2) {
                Text("+\(selectedDestinationOS.count - (compact ? 1 : 2))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if readyDestinationsOnly {
                DestinationFilterToken(title: "Ready") {
                    readyDestinationsOnly = false
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func destinationScopeButton(_ scope: DestinationScope, compact: Bool) -> some View {
        Button {
            destinationScope = scope
        } label: {
            if compact && scope != .all {
                Image(systemName: scope.symbol)
                    .frame(width: 14)
            } else if scope == .all {
                Text(scope.title)
            } else {
                Label(scope.title, systemImage: scope.symbol)
            }
        }
        .font(.caption.weight(.medium))
        .buttonStyle(DestinationScopeChipStyle(isSelected: destinationScope == scope))
        .help(scope.help)
        .accessibilityLabel(scope.title)
        .accessibilityAddTraits(destinationScope == scope ? .isSelected : [])
    }

    private func destinationMoreFiltersMenu(compact: Bool) -> some View {
        Menu {
            Menu("Operating System") {
                ForEach(availableDestinationOS, id: \.self) { os in
                    Button {
                        toggleDestinationOS(os)
                    } label: {
                        Label(os, systemImage: selectedDestinationOS.contains(os) ? "checkmark" : "circle")
                    }
                }
            }

            Menu("Device Type") {
                ForEach([DestinationScope.all, .mac, .physical, .simulators]) { scope in
                    Button {
                        destinationScope = scope
                    } label: {
                        Label(scope.title, systemImage: destinationScope == scope ? "checkmark" : scope.symbol)
                    }
                }
            }

            Divider()
            Toggle("Ready only", isOn: $readyDestinationsOnly)

            if hasStructuredDestinationFilters {
                Divider()
                Button("Clear Filters") {
                    clearDestinationFilters(includeSearch: false)
                }
            }
        } label: {
            if compact {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption.weight(.medium))
            } else {
                Label("More", systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.medium))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
        }
        .help("More destination filters")
    }

    @ViewBuilder
    private func destinationGroup(
        title: String,
        kind: DestinationKind,
        destinations matching: [Destination]
    ) -> some View {
        let readyCount = matching.count(where: \.isReadyForDevelopment)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: destinationSymbol(for: kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                Spacer()
                HealthBadge(
                    title: matching.isEmpty ? "None found" : "\(readyCount) of \(matching.count) ready",
                    isHealthy: !matching.isEmpty && readyCount == matching.count,
                    isEmpty: matching.isEmpty
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if matching.isEmpty {
                Text(emptyDestinationMessage(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
            } else if destinationLayout == .list {
                Divider()
                ForEach(Array(matching.enumerated()), id: \.element.id) { index, destination in
                    DestinationRow(
                        destination: destination,
                        isSelected: model.selectedDestinationIDs.contains(destination.id),
                        isFavorite: favoriteDestinationIDs.contains(destination.id),
                        setSelected: { isSelected in
                            DispatchQueue.main.async {
                                model.setDestination(destination.id, isSelected: isSelected)
                            }
                        },
                        setFavorite: { isFavorite in
                            setDestinationFavorite(destination.id, isFavorite: isFavorite)
                        }
                    )
                    if index < matching.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            } else {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(matching) { destination in
                        DestinationGridCard(
                            destination: destination,
                            isSelected: model.selectedDestinationIDs.contains(destination.id),
                            isFavorite: favoriteDestinationIDs.contains(destination.id),
                            setSelected: { isSelected in
                                model.setDestination(destination.id, isSelected: isSelected)
                            },
                            setFavorite: { isFavorite in
                                setDestinationFavorite(destination.id, isFavorite: isFavorite)
                            }
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var logConsole: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                consoleToolbar(compact: false)
                consoleToolbar(compact: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(XerTheme.workspace)

            Divider()

            if filteredLogs.isEmpty {
                ContentUnavailableView {
                    Label(logQuery.isEmpty ? "No output yet" : "No matching output", systemImage: "text.alignleft")
                } description: {
                    Text(logQuery.isEmpty ? "Build commands and diagnostics will appear here." : "Try another search or log-level filter.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(XerTheme.inspector)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(filteredLogs) { entry in
                                LogLine(entry: entry)
                            }
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("console-bottom")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        guard autoScrollConsole else { return }
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                    .onChange(of: filteredLogs.count) {
                        guard autoScrollConsole else { return }
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
                .background(XerTheme.inspector)
                .accessibilityLabel("Build log output")
            }

            HStack {
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScrollConsole)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.regularMaterial)
        }
        .background(XerTheme.inspector)
    }

    private func consoleDivider(currentHeight: Double, maximumHeight: Double) -> some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 34, height: 3)
                .opacity(0.7)
        }
        .frame(height: 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if consoleResizeStart == nil {
                        consoleResizeStart = currentHeight
                    }
                    guard let consoleResizeStart else { return }
                    consoleDragHeight = min(
                        max(consoleResizeStart - Double(value.translation.height), 190),
                        maximumHeight
                    )
                }
                .onEnded { _ in
                    if let consoleDragHeight {
                        consoleHeight = min(max(consoleDragHeight, 190), maximumHeight)
                    }
                    consoleDragHeight = nil
                    consoleResizeStart = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize console")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                consoleHeight = min(currentHeight + 40, maximumHeight)
            case .decrement:
                consoleHeight = max(currentHeight - 40, 190)
            @unknown default:
                break
            }
        }
    }

    private func consoleToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Text("Console")
                .font(.headline)

            Spacer(minLength: 4)

            if compact {
                Button {
                    model.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.logs.isEmpty)
                .accessibilityLabel("Clear console")
            } else {
                Button("Clear") {
                    model.clearLogs()
                }
                .disabled(model.logs.isEmpty)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    filteredLogs.map(\.message).joined(separator: "\n"),
                    forType: .string
                )
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(filteredLogs.isEmpty)
            .help("Copy visible console output")
            .accessibilityLabel("Copy visible console output")

            logLevelPicker
                .frame(width: compact ? 100 : 120)

            consoleSearchField(width: compact ? 140 : 190)
        }
        .frame(maxWidth: .infinity)
    }

    private func consoleSearchField(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search output", text: $logQuery)
                .textFieldStyle(.plain)
                .focused($isLogSearchFocused)
                .onKeyPress(.escape) {
                    logQuery = ""
                    return .handled
                }
            if !logQuery.isEmpty {
                Button {
                    logQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear log search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 26)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var logLevelPicker: some View {
        Picker("Log level", selection: $logFilter) {
            ForEach(LogFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel("Filter activity")
    }

    private var commandBar: some View {
        HStack(spacing: 12) {
            Button("Manage Devices…") {
                model.openDeviceManager()
            }
            .buttonStyle(.bordered)
            .help("Open Xcode to manage devices and simulators")

            Spacer()

            if model.isBusy {
                Button {
                    model.cancelCurrentOperation()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .keyboardShortcut(".", modifiers: [.command])
                .help("Cancel the current operation (⌘.)")
            } else {
                Button {
                    model.buildInstallAndLaunchSelected()
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canBuildAndDeploy)
                .help("Build, install, and launch on selected destinations (⌘Return)")
                .accessibilityLabel("Build, install, and launch on \(model.selectedDestinations.count) selected destinations")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(XerTheme.workspace)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Operation failed")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Spacer()
            Button("Dismiss") { model.clearError() }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func developerToolsCallout(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warningLooksLikeToolFailure(warning) ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(warningLooksLikeToolFailure(warning) ? "Developer tools need attention" : "Some destinations are unavailable")
                    .font(.callout.weight(.semibold))
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if warningLooksLikeToolFailure(warning) {
                    Text("Install Xcode, open Xcode › Settings › Locations, choose Command Line Tools, then refresh destinations.")
                        .font(.caption.weight(.medium))
                }
            }
            Spacer()
            Button("Refresh") { model.refreshDestinations() }
                .disabled(model.isBusy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var favoriteDestinationIDs: Set<String> {
        Set(favoriteDestinationStorage.split(separator: "\n").map(String.init))
    }

    private var availableDestinationOS: [String] {
        Set(model.destinations.map { destinationOSLabel($0) }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var hasStructuredDestinationFilters: Bool {
        destinationScope != .all || !selectedDestinationOS.isEmpty || readyDestinationsOnly
    }

    private var visibleDestinations: [Destination] {
        let matches = model.filteredDestinations.filter { destination in
            let matchesScope: Bool
            switch destinationScope {
            case .all:
                matchesScope = true
            case .favorites:
                matchesScope = favoriteDestinationIDs.contains(destination.id)
            case .mac:
                matchesScope = destination.kind == .localMac
            case .physical:
                matchesScope = destination.kind == .physicalDevice
            case .simulators:
                matchesScope = destination.kind == .simulator
            }

            return matchesScope
                && (selectedDestinationOS.isEmpty || selectedDestinationOS.contains(destinationOSLabel(destination)))
                && (!readyDestinationsOnly || destination.isReadyForDevelopment)
        }

        let sorted = Destination.sorted(matches)
        return sorted.filter { favoriteDestinationIDs.contains($0.id) }
            + sorted.filter { !favoriteDestinationIDs.contains($0.id) }
    }

    private var filteredSimulators: [Destination] {
        visibleDestinations.filter { $0.kind == .simulator }
    }

    private var filteredLocalMacs: [Destination] {
        visibleDestinations.filter { $0.kind == .localMac }
    }

    private var filteredConnectedDestinations: [Destination] {
        visibleDestinations.filter { $0.kind == .physicalDevice && $0.isConnected }
    }

    private var destinationPresentationGroups: [DestinationPresentationGroup] {
        [
            DestinationPresentationGroup(id: "mac", title: "Mac", kind: .localMac, destinations: filteredLocalMacs),
            DestinationPresentationGroup(id: "physical", title: "iOS Devices", kind: .physicalDevice, destinations: filteredConnectedDestinations),
            DestinationPresentationGroup(id: "simulators", title: "Simulators", kind: .simulator, destinations: filteredSimulators),
            DestinationPresentationGroup(id: "unavailable", title: "Unavailable Devices", kind: .physicalDevice, destinations: filteredUnavailablePhysicalDevices)
        ]
        .filter { !$0.destinations.isEmpty }
    }

    private func destinationSymbol(for kind: DestinationKind) -> String {
        switch kind {
        case .localMac: "desktopcomputer"
        case .simulator: "iphone.gen3"
        case .physicalDevice: "cable.connector.horizontal"
        }
    }

    private func emptyDestinationMessage(for kind: DestinationKind) -> String {
        let searching = !model.destinationSearchQuery.isEmpty
        switch kind {
        case .localMac:
            return searching ? "This Mac does not match this search." : "This Mac is not available."
        case .simulator:
            return searching ? "No simulators match this search." : "No available Simulator runtimes were reported by simctl."
        case .physicalDevice:
            return searching ? "No connected physical devices match this search." : "No connected physical devices were reported by devicectl."
        }
    }

    private var filteredUnavailablePhysicalDevices: [Destination] {
        visibleDestinations.filter {
            $0.kind == .physicalDevice && !$0.isConnected
        }
    }

    private var destinationEmptyDescription: String {
        if destinationScope == .favorites && favoriteDestinationIDs.isEmpty {
            return "Favorite a device with its star button to keep it in this quick view."
        }
        if !model.destinationSearchQuery.isEmpty {
            return "No device matches “\(model.destinationSearchQuery)” and the active filters."
        }
        return "No destinations match the active OS, device type, favorites, or readiness filters."
    }

    private func destinationOSLabel(_ destination: Destination) -> String {
        guard let version = destination.osVersion, !version.isEmpty else {
            return destination.platform
        }
        return "\(destination.platform) \(version)"
    }

    private func toggleDestinationOS(_ os: String) {
        if selectedDestinationOS.contains(os) {
            selectedDestinationOS.remove(os)
        } else {
            selectedDestinationOS.insert(os)
        }
    }

    private func clearDestinationFilters(includeSearch: Bool) {
        destinationScope = .all
        selectedDestinationOS.removeAll()
        readyDestinationsOnly = false
        if includeSearch {
            model.setDestinationSearchQuery("")
        }
    }

    private func setDestinationFavorite(_ destinationID: String, isFavorite: Bool) {
        var favorites = favoriteDestinationIDs
        if isFavorite {
            favorites.insert(destinationID)
        } else {
            favorites.remove(destinationID)
        }
        favoriteDestinationStorage = favorites.sorted().joined(separator: "\n")
    }

    private func warningLooksLikeToolFailure(_ warning: String) -> Bool {
        let value = warning.lowercased()
        return value.contains("developer tool") || value.contains("xcode") || value.contains("xcrun") || value.contains("command not found") || value.contains("no such file")
    }

    private var filteredLogs: [LogEntry] {
        model.logs.filter { entry in
            logFilter.includes(entry.level)
                && (logQuery.isEmpty || entry.message.localizedCaseInsensitiveContains(logQuery))
        }
    }

    private var filteredProjects: [ImportedProject] {
        guard !projectQuery.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.displayName.localizedCaseInsensitiveContains(projectQuery)
                || $0.path.localizedCaseInsensitiveContains(projectQuery)
        }
    }

    private var filteredProjectGroups: [SidebarProjectGroup] {
        let grouped = Dictionary(grouping: filteredProjects) { project in
            project.parentPath
                ?? project.url.deletingLastPathComponent().standardizedFileURL.path
        }
        return grouped.map { folderPath, projects in
            SidebarProjectGroup(
                folderPath: folderPath,
                projects: projects.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                },
                totalProjectCount: model.projects.count { project in
                    let projectFolderPath = project.parentPath
                        ?? project.url.deletingLastPathComponent().standardizedFileURL.path
                    return URL(fileURLWithPath: projectFolderPath, isDirectory: true)
                        .standardizedFileURL.path == URL(fileURLWithPath: folderPath, isDirectory: true)
                        .standardizedFileURL.path
                }
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $projectQuery)
                .textFieldStyle(.plain)
            if !projectQuery.isEmpty {
                Button {
                    projectQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct FullWidthMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

private struct FullWidthMenuControl<MenuItems: View>: View {
    let title: String
    let systemImage: String
    private let menuItems: () -> MenuItems

    init(
        title: String,
        systemImage: String,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.title = title
        self.systemImage = systemImage
        self.menuItems = menuItems
    }

    var body: some View {
        ZStack {
            FullWidthMenuLabel(title: title, systemImage: systemImage)
                .allowsHitTesting(false)

            Menu {
                menuItems()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .contentShape(Rectangle())
    }
}

private struct DestinationSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Filter destinations", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onKeyPress(.escape) {
                    text = ""
                    return .handled
                }
                .accessibilityLabel("Search destinations")
                .accessibilityHint("Search by device name, simulator, operating system, status, or identifier")

            if text.isEmpty {
                Text("⌥⌘F")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination search")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isFocused.wrappedValue ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct InstalledAppSummary: View {
    let apps: [InstalledApp]

    private var firstApp: InstalledApp { apps[0] }
    private var representativeApp: InstalledApp {
        apps.first(where: { $0.icon?.isUsable == true }) ?? firstApp
    }

    var body: some View {
        HStack(spacing: 7) {
            InstalledAppIcon(icon: representativeApp.icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(firstApp.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(apps.count == 1 ? firstApp.destination.name : "\(apps.count) destinations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 2)
        .help(apps.map { "\($0.displayName) — \($0.destination.name)" }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(apps.count == 1
            ? "Installed app \(firstApp.displayName) on \(firstApp.destination.name)"
            : "Installed app \(firstApp.displayName) on \(apps.count) destinations")
    }
}

private struct InstalledAppIcon: View {
    let icon: AppIcon?

    var body: some View {
        AppIconArtwork(
            icon: icon,
            fallbackSystemName: "app.fill",
            fallbackColor: Color.accentColor
        )
    }
}

private struct ProjectRow: View {
    let project: ImportedProject
    let icon: AppIcon?

    var body: some View {
        HStack(spacing: 9) {
            AppIconArtwork(
                icon: icon,
                fallbackSystemName: project.kind == .workspace ? "square.stack.3d.up" : "hammer",
                fallbackColor: project.isTrusted ? Color.accentColor : Color.orange,
                size: 34
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(compactPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityValue(project.isTrusted ? "Trusted" : "Trust required")
    }

    private var compactPath: String {
        (project.path as NSString).abbreviatingWithTildeInPath
    }
}

private struct AppIconArtwork: View {
    let icon: AppIcon?
    let fallbackSystemName: String
    let fallbackColor: Color
    var size: CGFloat = 28

    var body: some View {
        let image = resolvedImage
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(fallbackColor.opacity(0.13))
                    Image(systemName: fallbackSystemName)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(fallbackColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            if image != nil {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
        .shadow(
            color: image == nil ? .clear : Color.black.opacity(0.22),
            radius: 1.5,
            x: 0,
            y: 1
        )
        .accessibilityHidden(true)
    }

    private var resolvedImage: NSImage? {
        if let icon, !icon.data.isEmpty, let image = NSImage(data: icon.data) {
            return image
        }
        if let url = icon?.sourceURL {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

private struct DestinationRow: View {
    let destination: Destination
    let isSelected: Bool
    let isFavorite: Bool
    let setSelected: (Bool) -> Void
    let setFavorite: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                setSelected(!isSelected)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? XerTheme.action : Color.secondary)
                        .frame(width: 20)

                    Image(systemName: destinationIcon)
                        .foregroundStyle(Color.secondary)
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(destination.name)
                                .font(.callout.weight(.medium))
                            Circle()
                                .fill(destination.isReadyForDevelopment ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            if !destination.isReadyForDevelopment {
                                Text("Unavailable")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(destination.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    if destination.kind == .physicalDevice,
                       let modelName = destination.modelName,
                       !modelName.localizedCaseInsensitiveContains(destination.name) {
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let batteryLevel = destination.batteryLevel {
                        HStack(spacing: 4) {
                            Text("\(batteryLevel)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: batterySymbol(for: batteryLevel))
                                .foregroundStyle(batteryLevel <= 20 ? Color.orange : Color.green)
                        }
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!destination.isReadyForDevelopment)
            .accessibilityLabel("\(destination.name), \(destination.kind.displayName), \(destination.isReadyForDevelopment ? "ready" : "unavailable")")
            .accessibilityHint(destination.isReadyForDevelopment ? "Select this build destination" : "Reconnect, pair, or enable Developer Mode before selecting")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                setFavorite(!isFavorite)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFavorite ? "Remove \(destination.name) from favorites" : "Add \(destination.name) to favorites")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? XerTheme.action.opacity(0.15)
                : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .help(destination.udid)
    }

    private func batterySymbol(for level: Int) -> String {
        switch level {
        case ...10: "battery.0percent"
        case ...35: "battery.25percent"
        case ...65: "battery.50percent"
        case ...90: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var destinationIcon: String {
        switch destination.kind {
        case .localMac: "desktopcomputer"
        case .simulator: "iphone.gen3"
        case .physicalDevice: "iphone"
        }
    }
}

private struct DestinationGridCard: View {
    let destination: Destination
    let isSelected: Bool
    let isFavorite: Bool
    let setSelected: (Bool) -> Void
    let setFavorite: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                setSelected(!isSelected)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: destinationIcon)
                        .font(.system(size: 23))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(destination.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Label(
                            destination.isReadyForDevelopment ? "Ready" : "Unavailable",
                            systemImage: destination.isReadyForDevelopment ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(destination.isReadyForDevelopment ? Color.green : Color.orange)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? XerTheme.action : Color.secondary)
                        .padding(.top, 22)
                }
                .padding(10)
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .background(
                    isSelected ? XerTheme.action.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? XerTheme.action.opacity(0.45) : Color(nsColor: .separatorColor))
                }
            }
            .buttonStyle(.plain)
            .disabled(!destination.isReadyForDevelopment)
            .accessibilityLabel("\(destination.name), \(destination.kind.displayName), \(destination.isReadyForDevelopment ? "ready" : "unavailable")")
            .accessibilityHint(destination.isReadyForDevelopment ? "Select this build destination" : "Reconnect, pair, or enable Developer Mode before selecting")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                setFavorite(!isFavorite)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFavorite ? "Remove \(destination.name) from favorites" : "Add \(destination.name) to favorites")
        }
        .help(destination.udid)
    }

    private var destinationIcon: String {
        switch destination.kind {
        case .localMac: "desktopcomputer"
        case .simulator: "iphone.gen3"
        case .physicalDevice: "iphone"
        }
    }
}

private struct HealthBadge: View {
    let title: String
    let isHealthy: Bool
    let isEmpty: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isEmpty ? Color.secondary : (isHealthy ? Color.green : Color.orange))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OperationStatus: View {
    let state: AppOperationState
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isBusy && state != .running {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(state.title)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }

            Text(phaseTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if let progress {
                Divider()
                    .frame(height: 11)

                Text("\(progress.completed)/\(progress.total)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(statusColor.opacity(backgroundOpacity), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(statusColor.opacity(borderOpacity), lineWidth: 0.75)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(state.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.title)
    }

    private var progress: (completed: Int, total: Int)? {
        switch state {
        case let .building(completed, total), let .installing(completed, total):
            return (completed, max(total, 1))
        default:
            return nil
        }
    }

    private var phaseTitle: String {
        switch state {
        case .idle: "Ready"
        case .importing: "Importing"
        case .refreshingDestinations: "Refreshing destinations"
        case .refreshingSchemes: "Refreshing schemes"
        case .preparingBuild: "Constructing build description"
        case .building: "Building"
        case .installing: "Installing"
        case .launching: "Launching"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var statusSymbol: String {
        switch state {
        case .idle: "checkmark"
        case .succeeded: "checkmark.circle.fill"
        case .running: "circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        default: "circle.fill"
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle: .secondary
        case .succeeded, .running: .green
        case .failed: .red
        case .cancelled: .orange
        default: XerTheme.action
        }
    }

    private var backgroundOpacity: Double {
        switch state {
        case .idle: 0.06
        case .failed, .cancelled, .succeeded, .running: 0.10
        default: 0.09
        }
    }

    private var borderOpacity: Double {
        switch state {
        case .idle: 0.16
        default: 0.22
        }
    }
}

private struct LogLine: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(levelTitle)
                .foregroundStyle(levelColor)
                .frame(width: 42, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var levelTitle: String {
        switch entry.level {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .command: "CMD"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .command: .blue
        }
    }
}

private enum LogFilter: String, CaseIterable, Identifiable {
    case all
    case commands
    case warnings
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .commands: "Commands"
        case .warnings: "Warnings"
        case .errors: "Errors"
        }
    }

    func includes(_ level: LogEntry.Level) -> Bool {
        switch self {
        case .all: true
        case .commands: level == .command
        case .warnings: level == .warning
        case .errors: level == .error
        }
    }
}

private enum DestinationLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
}

private struct DestinationPresentationGroup {
    let id: String
    let title: String
    let kind: DestinationKind
    let destinations: [Destination]
}

private enum DestinationScope: String, CaseIterable, Identifiable {
    case all
    case favorites
    case mac
    case physical
    case simulators

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .mac: "Mac"
        case .physical: "Physical"
        case .simulators: "Simulators"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .mac: "desktopcomputer"
        case .physical: "iphone"
        case .simulators: "iphone.gen3"
        }
    }

    var help: String {
        switch self {
        case .all: "Show all destinations"
        case .favorites: "Show favorite destinations"
        case .mac: "Show Mac destinations"
        case .physical: "Show physical devices"
        case .simulators: "Show simulators"
        }
    }
}

private struct DestinationScopeChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? XerTheme.action : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
                }
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct DestinationFilterToken: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(XerTheme.action)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(XerTheme.action.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Remove \(title) filter")
        .accessibilityLabel("Remove \(title) filter")
    }
}
