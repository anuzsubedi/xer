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
    @State private var consoleResizeStart: Double?
    @AppStorage("xer.consoleHeight") private var consoleHeight = 390.0
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
                let resolvedConsoleHeight = min(max(consoleHeight, 190.0), maximumConsoleHeight)

                VStack(spacing: 0) {
                    Group {
                        if usesSplitWorkspace { wideWorkspace(project) }
                        else { compactWorkspace(project) }
                    }
                    .frame(height: proxy.size.height - CGFloat(resolvedConsoleHeight) - 5)

                    consoleDivider(maximumHeight: maximumConsoleHeight)

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
            } else if model.filteredDestinations.isEmpty {
                ContentUnavailableView {
                    Label("No matching destinations", systemImage: "magnifyingglass")
                } description: {
                    Text("No device, simulator, OS version, status, or identifier matches “\(model.destinationSearchQuery)”.")
                } actions: {
                    Button("Clear Search") {
                        model.setDestinationSearchQuery("")
                        isDestinationSearchFocused = true
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    destinationGroup(
                        title: "Mac",
                        kind: .localMac,
                        destinations: filteredLocalMacs
                    )
                    Divider()
                    destinationGroup(
                        title: "iOS Devices",
                        kind: .physicalDevice,
                        destinations: model.connectedDestinations
                    )
                    Divider()
                    destinationGroup(
                        title: "Simulators",
                        kind: .simulator,
                        destinations: filteredSimulators
                    )
                    if !filteredUnavailablePhysicalDevices.isEmpty {
                        Divider()
                        destinationGroup(
                            title: "Unavailable Devices",
                            kind: .physicalDevice,
                            destinations: filteredUnavailablePhysicalDevices
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
                        setSelected: { isSelected in
                            DispatchQueue.main.async {
                                model.setDestination(destination.id, isSelected: isSelected)
                            }
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
                            setSelected: { isSelected in
                                model.setDestination(destination.id, isSelected: isSelected)
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

    private func consoleDivider(maximumHeight: Double) -> some View {
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
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if consoleResizeStart == nil {
                        consoleResizeStart = consoleHeight
                    }
                    guard let consoleResizeStart else { return }
                    consoleHeight = min(
                        max(consoleResizeStart - Double(value.translation.height), 190),
                        maximumHeight
                    )
                }
                .onEnded { _ in
                    consoleResizeStart = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize console")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                consoleHeight = min(consoleHeight + 40, maximumHeight)
            case .decrement:
                consoleHeight = max(consoleHeight - 40, 190)
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

    private var filteredSimulators: [Destination] {
        model.filteredDestinations.filter { $0.kind == .simulator }
    }

    private var filteredLocalMacs: [Destination] {
        model.filteredDestinations.filter { $0.kind == .localMac }
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
        model.filteredDestinations.filter {
            $0.kind == .physicalDevice && !$0.isConnected
        }
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
    let setSelected: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? XerTheme.action.opacity(0.15)
                    : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(!destination.isReadyForDevelopment)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .help(destination.udid)
        .accessibilityLabel("\(destination.name), \(destination.kind.displayName), \(destination.isReadyForDevelopment ? "ready" : "unavailable")")
        .accessibilityHint(destination.isReadyForDevelopment ? "Select this build destination" : "Reconnect, pair, or enable Developer Mode before selecting")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let setSelected: (Bool) -> Void

    var body: some View {
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
            }
            .padding(10)
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
        HStack(spacing: 9) {
            if isBusy {
                ProgressView(value: progress?.completed, total: progress?.total ?? 1)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityLabel(state.title)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.callout.weight(.medium))
                if let progress {
                    Text("\(Int(progress.completed)) of \(Int(progress.total)) destinations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: (completed: Double, total: Double)? {
        switch state {
        case let .building(completed, total), let .deploying(completed, total):
            return (Double(completed), Double(max(total, 1)))
        default:
            return nil
        }
    }

    private var statusSymbol: String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        default: "circle.fill"
        }
    }

    private var statusColor: Color {
        switch state {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .orange
        default: .secondary
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
