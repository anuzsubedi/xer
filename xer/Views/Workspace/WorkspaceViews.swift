import AppKit
import SwiftUI

extension ContentView {

    @ViewBuilder
    var detailPane: some View {
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

    func wideWorkspace(_ project: ImportedProject) -> some View {
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

    func compactWorkspace(_ project: ImportedProject) -> some View {
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

    var responsivePanePadding: CGFloat { 18 }

    var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("Choose a project", systemImage: "hammer")
        } description: {
            Text("Select a discovered project in the sidebar, or import a folder or project to begin.")
        } actions: {
            Button("Import Folder…") {
                model.chooseAndImportParentFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model.isBusy)

            Button("Add Project…") {
                model.chooseAndImportProject()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model.isBusy)

            Button("Terminal Commands…") {
                showTerminalCommands = true
            }
        }
    }

    func routeSection(_ project: ImportedProject) -> some View {
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
                HStack(alignment: .top, spacing: 8) {
                    Label("No scheme was found on disk. xer will load Xcode’s scheme list for this trusted project.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Load Schemes") {
                        model.refreshSchemes()
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    func actionSegment(
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
    func routeScheme(_ project: ImportedProject) -> some View {
        if project.schemes.isEmpty {
            Text("No schemes")
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
}
