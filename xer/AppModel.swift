import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let maxConcurrentDestinationOperations = 2

    @Published private(set) var projects: [ImportedProject] = []
    @Published private(set) var destinations: [Destination] = []
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var operationState: AppOperationState = .idle
    @Published private(set) var parentFolderURL: URL?
    @Published private(set) var destinationWarning: String?
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var projectIcons: [String: AppIcon] = [:]
    @Published var destinationSearchQuery = ""
    @Published var buildConfiguration = "Debug"
    @Published var cleanBuildFolder = false
    @Published var openConsoleForOutput = true
    @Published var includeUnifiedLogs = false
    @Published var automaticallySelectRunningDestination = false
    @Published private(set) var selectedProjectID: String?
    @Published var selectedDestinationIDs: Set<String> = []
    @Published private(set) var lastErrorMessage: String?
    @Published private var selectedSchemeByProject: [String: String] = [:]

    private let tooling: DeveloperTooling
    private let discovery: ProjectDiscovery
    private let bookmarkStore: BookmarkStore
    private var projectScopes: [String: SecurityScopeAccess] = [:]
    private var parentScope: SecurityScopeAccess?
    private var operationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var projectIconTask: Task<Void, Never>?
    private var latestBuildArtifacts: [String: BuildArtifact] = [:]
    private var hasRestored = false

    init(
        tooling: DeveloperTooling = DeveloperTooling(),
        discovery: ProjectDiscovery = ProjectDiscovery(),
        bookmarkStore: BookmarkStore = BookmarkStore()
    ) {
        self.tooling = tooling
        self.discovery = discovery
        self.bookmarkStore = bookmarkStore
    }

    var isBusy: Bool { operationTask != nil || restartTask != nil }
    var canStop: Bool { isBusy }
    var isAppActive: Bool {
        guard operationTask != nil else { return false }
        return operationState == .launching || operationState == .running
    }

    var canRunOrRestart: Bool {
        guard let project = selectedProject,
              project.isTrusted,
              let scheme = selectedSchemeName,
              !scheme.isEmpty,
              !selectedDestinations.isEmpty,
              restartTask == nil else {
            return false
        }
        return operationTask == nil || isAppActive
    }

    var selectedProject: ImportedProject? {
        guard let selectedProjectID else { return projects.first }
        return projects.first { $0.id == selectedProjectID }
    }

    var selectedSchemeName: String? {
        guard let project = selectedProject else { return nil }
        if let selected = selectedSchemeByProject[project.id],
           project.schemes.contains(where: { $0.name == selected }) {
            return selected
        }
        return project.schemes.first?.name
    }

    var selectedDestinations: [Destination] {
        Destination.sorted(destinations.filter { $0.isReadyForDevelopment && selectedDestinationIDs.contains($0.id) })
    }

    func projectIcon(for project: ImportedProject) -> AppIcon? {
        projectIcons[project.id]
    }

    /// Model-layer destination filtering used by any future presentation. The
    /// query is tokenized, case/diacritic-insensitive, and matches names,
    /// platform, OS, identifiers, and status aliases.
    var filteredDestinations: [Destination] {
        Destination.sorted(destinations.filter { $0.matchesSearch(destinationSearchQuery) })
    }

    var connectedDestinations: [Destination] {
        filteredDestinations.filter { $0.kind == .physicalDevice && $0.isConnected }
    }

    var otherDestinations: [Destination] {
        filteredDestinations.filter { !($0.kind == .physicalDevice && $0.isConnected) }
    }

    func setDestinationSearchQuery(_ query: String) {
        destinationSearchQuery = query
    }

    var logText: String {
        logs.map { entry in
            let formatter = Self.logDateFormatter
            let level: String
            switch entry.level {
            case .info: level = "INFO"
            case .warning: level = "WARN"
            case .error: level = "ERROR"
            case .command: level = "CMD"
            }
            return "[\(formatter.string(from: entry.date))] [\(level)] \(entry.message)"
        }.joined(separator: "\n")
    }

    var canBuildAndDeploy: Bool {
        guard let project = selectedProject,
              project.isTrusted,
              let scheme = selectedSchemeName,
              !scheme.isEmpty,
              !selectedDestinations.isEmpty else {
            return false
        }
        return !isBusy
    }

    var canBuild: Bool { canBuildAndDeploy }

    var canInstall: Bool {
        let selected = selectedDestinations
        return !isBusy
            && !selected.isEmpty
            && selected.allSatisfy { latestBuildArtifacts[$0.id] != nil }
    }

    func restorePersistedProjects() {
        guard !hasRestored else { return }
        hasRestored = true

        if let restoredParent = bookmarkStore.resolveParentFolder() {
            let normalizedParent = restoredParent.standardizedFileURL
            let scope = SecurityScopeAccess(url: normalizedParent)
            if FileManager.default.fileExists(atPath: normalizedParent.path),
               (try? normalizedParent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                parentFolderURL = normalizedParent
                parentScope = scope
            }
        }

        var restoredProjects: [ImportedProject] = []
        var scopes: [String: SecurityScopeAccess] = [:]
        for record in bookmarkStore.storedProjects() {
            guard let resolvedURL = bookmarkStore.resolveProject(record) else {
                continue
            }

            let normalizedURL = resolvedURL.standardizedFileURL
            guard let resolvedKind = discovery.kind(of: normalizedURL) else {
                continue
            }
            let scope = SecurityScopeAccess(url: normalizedURL)
            guard FileManager.default.fileExists(atPath: normalizedURL.path),
                  (try? normalizedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let project = ImportedProject(
                path: normalizedURL.path,
                kind: resolvedKind,
                schemes: record.schemes,
                isTrusted: record.isTrusted,
                parentPath: record.parentPath
            )
            restoredProjects.append(project)
            scopes[project.path] = scope
            if let scheme = project.schemes.first?.name {
                selectedSchemeByProject[project.id] = scheme
            }
        }

        projects = restoredProjects.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        projectScopes = scopes
        selectedProjectID = projects.first?.id
        refreshProjectIcons(for: projects)

        if !projects.isEmpty {
            appendLog(.info, "Restored \(projects.count) persisted project record(s).")
        }
    }

    func chooseAndImportParentFolder() {
        guard !isBusy else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Parent Folder"
        panel.message = "Choose a folder containing .xcworkspace or .xcodeproj packages."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importParentFolder(url)
    }

    func importParentFolder(_ url: URL) {
        guard !isBusy else { return }
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            presentError("The selected parent folder no longer exists.")
            return
        }

        lastErrorMessage = nil
        operationState = .importing
        appendLog(.command, "Inspecting imported folder \(normalizedURL.path)")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performImport(from: normalizedURL)
            self.operationTask = nil
        }
    }

    func refreshDestinations() {
        guard !isBusy else { return }
        lastErrorMessage = nil
        destinationWarning = nil
        operationState = .refreshingDestinations
        appendLog(.command, "Refreshing This Mac, simulators, and connected physical devices with Apple developer tools.")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDestinationRefresh()
            self.operationTask = nil
        }
    }

    func runOrRestart() {
        guard canRunOrRestart else { return }
        guard operationTask != nil else {
            buildInstallAndLaunchSelected()
            return
        }

        appendLog(.command, "Run requested while the app is active. Stopping it before rebuilding, installing, and relaunching.")
        operationTask?.cancel()
        tooling.cancelAll()

        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while self.operationTask != nil {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                self.restartTask = nil
                return
            }

            self.restartTask = nil
            self.buildInstallAndLaunchSelected()
        }
    }

    func refreshSchemes() {
        guard !isBusy else { return }
        guard let project = selectedProject else {
            presentError("Import a project before refreshing schemes.")
            return
        }
        guard project.isTrusted else {
            presentError("Trust this imported project before running xcodebuild to refresh its schemes.")
            return
        }

        lastErrorMessage = nil
        operationState = .refreshingSchemes
        appendLog(.command, "Refreshing shared schemes for \(project.displayName) with xcodebuild.")
        appendLog(.command, commandDescription(DeveloperTooling.schemeListArguments(for: project)))
        let handler = outputHandler(label: "schemes \(project.displayName)")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let schemes = try await self.tooling.listSchemes(for: project, outputHandler: handler)
                self.updateProjectSchemes(projectID: project.id, schemes: schemes)
                if schemes.isEmpty {
                    self.appendLog(.warning, "No shared schemes were returned for \(project.displayName).")
                } else {
                    self.appendLog(.info, "Found \(schemes.count) shared scheme(s) for \(project.displayName).")
                }
                self.operationState = .succeeded
            } catch is CancellationError {
                self.operationState = .cancelled
                self.appendLog(.warning, "Scheme refresh cancelled.")
            } catch {
                let message = UserFacingError.describe(error)
                self.presentOperationFailure(message)
            }
            self.operationTask = nil
        }
    }

    func trustProject(_ projectID: String) {
        guard !isBusy,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var project = projects[index]
        guard !project.isTrusted else { return }
        project.isTrusted = true
        projects[index] = project
        persistProject(project)
        appendLog(.info, "Trusted \(project.displayName). Build phases and signing configuration may now run when explicitly requested.")
    }

    func revokeTrust(for projectID: String) {
        guard !isBusy,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var project = projects[index]
        project.isTrusted = false
        projects[index] = project
        persistProject(project)
        appendLog(.warning, "Trust revoked for \(project.displayName).")
    }

    func selectProject(_ projectID: String?) {
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else { return }
        selectedProjectID = projectID
        latestBuildArtifacts.removeAll()
    }

    func selectScheme(_ schemeName: String?) {
        guard let project = selectedProject else { return }
        guard let schemeName else {
            selectedSchemeByProject.removeValue(forKey: project.id)
            return
        }
        guard project.schemes.contains(where: { $0.name == schemeName }) else { return }
        selectedSchemeByProject[project.id] = schemeName
        latestBuildArtifacts.removeAll()
    }

    func selectBuildConfiguration(_ configuration: String) {
        guard ["Debug", "Release"].contains(configuration) else { return }
        buildConfiguration = configuration
        latestBuildArtifacts.removeAll()
    }

    func setDestination(_ destinationID: String, isSelected: Bool) {
        if isSelected {
            selectedDestinationIDs.insert(destinationID)
        } else {
            selectedDestinationIDs.remove(destinationID)
        }
    }

    func removeProject(_ projectID: String) {
        guard !isBusy,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let removed = projects.remove(at: index)
        projectScopes.removeValue(forKey: removed.path)
        projectIcons.removeValue(forKey: removed.id)
        selectedSchemeByProject.removeValue(forKey: removed.id)
        latestBuildArtifacts.removeAll()
        bookmarkStore.removeProjects(notIn: Set(projects.map(\.path)))

        if selectedProjectID == removed.id {
            selectedProjectID = projects.indices.contains(index)
                ? projects[index].id
                : projects.last?.id
        }
        appendLog(.info, "Removed \(removed.displayName) from xer. No project files were deleted.")
    }

    func removeImportedFolder(_ folderPath: String) {
        guard !isBusy else { return }
        let normalizedFolderPath = URL(fileURLWithPath: folderPath, isDirectory: true)
            .standardizedFileURL.path
        let removedProjects = projects.filter {
            let parentPath = $0.parentPath
                ?? $0.url.deletingLastPathComponent().standardizedFileURL.path
            return URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL.path
                == normalizedFolderPath
        }
        guard !removedProjects.isEmpty else { return }

        let removedIDs = Set(removedProjects.map(\.id))
        projects.removeAll { removedIDs.contains($0.id) }
        for project in removedProjects {
            projectScopes.removeValue(forKey: project.path)
            projectIcons.removeValue(forKey: project.id)
            selectedSchemeByProject.removeValue(forKey: project.id)
        }
        latestBuildArtifacts.removeAll()
        bookmarkStore.removeProjects(notIn: Set(projects.map(\.path)))
        bookmarkStore.removeParentFolder(matching: normalizedFolderPath)

        if let parentFolderURL,
           parentFolderURL.standardizedFileURL.path == normalizedFolderPath {
            self.parentFolderURL = nil
            parentScope = nil
        }
        if let selectedProjectID, removedIDs.contains(selectedProjectID) {
            self.selectedProjectID = projects.first?.id
        }

        let folderName = URL(fileURLWithPath: normalizedFolderPath, isDirectory: true).lastPathComponent
        appendLog(.info, "Removed imported folder \(folderName) and \(removedProjects.count) project record(s) from xer. No files were deleted.")
    }

    func openDeviceManager() {
        guard let xcodeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            presentError("Xcode could not be found. Install Xcode to manage Apple devices and simulators.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: xcodeURL,
                    configuration: configuration
                )
            } catch {
                presentError("Xcode could not be opened: \(error.localizedDescription)")
            }
        }
    }

    func buildSelected() {
        guard let context = validatedBuildContext() else { return }
        lastErrorMessage = nil
        installedApps.removeAll()
        latestBuildArtifacts.removeAll()
        operationState = .preparingBuild
        appendLog(.command, "Building \(context.scheme) for \(context.destinations.count) destination(s).")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcomes = await self.performBuildPhase(
                project: context.project,
                scheme: context.scheme,
                destinations: context.destinations,
                configuration: context.configuration,
                cleanBuildFolder: context.cleanBuildFolder
            )
            if Task.isCancelled {
                self.operationState = .cancelled
                self.appendLog(.warning, "Build cancelled.")
            } else {
                let failures = outcomes.compactMap(\.errorMessage)
                if failures.isEmpty {
                    self.operationState = .succeeded
                    self.appendLog(.info, "Build completed for all selected destinations.")
                } else {
                    self.presentOperationFailure(failures.joined(separator: "\n"))
                }
            }
            self.operationTask = nil
        }
    }

    func installSelected() {
        guard canInstall else {
            presentError("Build the selected destinations before installing.")
            return
        }
        let artifacts = selectedDestinations.compactMap { latestBuildArtifacts[$0.id] }
        operationState = .installing(completed: 0, total: artifacts.count)
        appendLog(.command, "Installing the latest build on \(artifacts.count) destination(s).")
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var completed = 0
            for batch in artifacts.batches(of: Self.maxConcurrentDestinationOperations) {
                let results = await withTaskGroup(of: DeployOutcome.self, returning: [DeployOutcome].self) { group in
                    for artifact in batch {
                        let handler = self.outputHandler(label: "install \(artifact.destination.name)")
                        group.addTask { [tooling = self.tooling, artifact, handler] in
                            do {
                                try await tooling.install(artifact: artifact, outputHandler: handler)
                                return DeployOutcome(destination: artifact.destination, artifact: artifact, errorMessage: nil)
                            } catch {
                                return DeployOutcome(destination: artifact.destination, artifact: nil, errorMessage: UserFacingError.describe(error))
                            }
                        }
                    }
                    return await group.reduce(into: []) { $0.append($1) }
                }
                completed += batch.count
                self.operationState = .installing(completed: completed, total: artifacts.count)
                for result in results {
                    if let error = result.errorMessage {
                        failures.append("\(result.destination.name): \(error)")
                        self.appendLog(.error, "Install failed for \(result.destination.name): \(error)")
                    } else if let artifact = result.artifact {
                        let installed = InstalledApp(artifact: artifact)
                        self.installedApps.removeAll { $0.id == installed.id }
                        self.installedApps.append(installed)
                        self.appendLog(.info, "Installed \(installed.displayName) on \(result.destination.name).")
                    }
                }
            }
            if Task.isCancelled {
                self.operationState = .cancelled
                self.appendLog(.warning, "Install cancelled.")
            } else if failures.isEmpty {
                self.operationState = .succeeded
                self.appendLog(.info, "Install completed for all selected destinations.")
            } else {
                self.presentOperationFailure(failures.joined(separator: "\n"))
            }
            self.operationTask = nil
        }
    }

    func buildInstallAndLaunchSelected() {
        guard !isBusy else { return }
        guard let project = selectedProject else {
            presentError("Import a project before building.")
            return
        }
        guard project.isTrusted else {
            presentError("Trust confirmation is required before building an imported project. Building can execute project-defined scripts.")
            return
        }
        guard let scheme = selectedSchemeName, !scheme.isEmpty else {
            presentError("Select a shared scheme before building.")
            return
        }
        let destinations = selectedDestinations
        guard !destinations.isEmpty else {
            presentError("Select at least one simulator or connected device.")
            return
        }

        lastErrorMessage = nil
        installedApps.removeAll()
        let configuration = buildConfiguration
        let shouldCleanBuildFolder = cleanBuildFolder
        let shouldAttachConsole = openConsoleForOutput
        let shouldIncludeUnifiedLogs = includeUnifiedLogs
        operationState = .preparingBuild
        appendLog(.command, "Starting bounded build/deploy for \(destinations.count) destination(s), max concurrency \(Self.maxConcurrentDestinationOperations).")
        for destination in destinations {
            let derivedDataURL = AppPaths.derivedDataURL(
                projectPath: project.path,
                scheme: scheme,
                destinationID: destination.id
            )
            appendLog(.command, commandDescription(DeveloperTooling.buildArguments(
                for: project,
                scheme: scheme,
                configuration: configuration,
                destination: destination,
                derivedDataURL: derivedDataURL
            )))
        }

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBuildAndDeploy(
                project: project,
                scheme: scheme,
                destinations: destinations,
                configuration: configuration,
                cleanBuildFolder: shouldCleanBuildFolder,
                attachConsole: shouldAttachConsole || shouldIncludeUnifiedLogs,
                includeUnifiedLogs: shouldIncludeUnifiedLogs
            )
            self.operationTask = nil
        }
    }

    func cancelCurrentOperation() {
        guard operationTask != nil || restartTask != nil else { return }
        operationState = .cancelling
        appendLog(.warning, "Cancellation requested. Stopping active developer tools…")
        operationTask?.cancel()
        restartTask?.cancel()
        tooling.cancelAll()
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func validatedBuildContext() -> BuildContext? {
        guard !isBusy else { return nil }
        guard let project = selectedProject else {
            presentError("Import a project before building.")
            return nil
        }
        guard project.isTrusted else {
            presentError("Trust confirmation is required before building an imported project. Building can execute project-defined scripts.")
            return nil
        }
        guard let scheme = selectedSchemeName, !scheme.isEmpty else {
            presentError("Select a shared scheme before building.")
            return nil
        }
        let destinations = selectedDestinations
        guard !destinations.isEmpty else {
            presentError("Select at least one simulator or connected device.")
            return nil
        }
        return BuildContext(
            project: project,
            scheme: scheme,
            destinations: destinations,
            configuration: buildConfiguration,
            cleanBuildFolder: cleanBuildFolder
        )
    }

    private func performImport(from parentURL: URL) async {
        do {
            try Task.checkCancellation()
            guard (try? parentURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw AppFailure(message: "Choose a folder, not a file.")
            }

            // Keep the access alive for the complete inspection and bookmark
            // write, but commit the new parent only after discovery succeeds.
            let parentAccess = SecurityScopeAccess(url: parentURL)
            let discovered = await Task.detached(priority: .userInitiated) { [discovery] in
                discovery.discover(in: parentURL)
            }.value
            guard !discovered.isEmpty else {
                throw AppFailure(message: "No .xcworkspace or .xcodeproj packages were found in \(parentURL.path).")
            }

            try Task.checkCancellation()

            let storedByPath = Dictionary(
                bookmarkStore.storedProjects().map { ($0.path, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            var imported: [ImportedProject] = []
            var newScopes: [String: SecurityScopeAccess] = [:]
            let discoveredSchemes = await Task.detached(priority: .userInitiated) { [discovery] in
                Dictionary(uniqueKeysWithValues: discovered.map { item in
                    (item.url.standardizedFileURL.path, discovery.sharedSchemes(in: item.url))
                })
            }.value

            for item in discovered {
                try Task.checkCancellation()
                let path = item.url.standardizedFileURL.path
                let previous = projects.first(where: { $0.path == path })
                let stored = storedByPath[path]
                let schemes = discoveredSchemes[path] ?? []
                let project = ImportedProject(
                    path: path,
                    kind: item.kind,
                    schemes: schemes,
                    isTrusted: previous?.isTrusted ?? stored?.isTrusted ?? false,
                    parentPath: parentURL.path
                )

                newScopes[path] = SecurityScopeAccess(url: item.url)
                imported.append(project)

                if schemes.isEmpty {
                    appendLog(.warning, "\(project.displayName) has no scheme files in xcshareddata/xcschemes. Trust it and use Refresh Schemes for xcodebuild's canonical list.")
                } else {
                    appendLog(.info, "Discovered \(schemes.count) shared scheme(s) in \(project.displayName) without executing project build phases.")
                }
            }

            try Task.checkCancellation()
            if !bookmarkStore.saveParentFolder(parentURL) {
                appendLog(.warning, "Could not persist a security-scoped bookmark for \(parentURL.path). The folder may need to be imported again after restarting xer.")
            }
            let normalizedParentPath = parentURL.standardizedFileURL.path
            let importedPaths = Set(imported.map(\.path))
            let retainedProjects = projects.filter { project in
                let existingParentPath = project.parentPath.map {
                    URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
                }
                return existingParentPath != normalizedParentPath && !importedPaths.contains(project.path)
            }
            let mergedProjects = (retainedProjects + imported).sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            for project in imported {
                persistProject(project)
            }
            bookmarkStore.removeProjects(notIn: Set(mergedProjects.map(\.path)))

            parentScope = parentAccess
            parentFolderURL = parentURL
            projects = mergedProjects
            projectScopes = projectScopes.filter { path, _ in
                retainedProjects.contains(where: { $0.path == path })
            }
            projectScopes.merge(newScopes) { _, latest in latest }
            selectedProjectID = imported.first?.id ?? projects.first?.id
            refreshProjectIcons(for: projects)
            selectedSchemeByProject = Dictionary(
                projects.compactMap { project in
                    guard let scheme = project.schemes.first?.name else { return nil }
                    return (project.id, scheme)
                },
                uniquingKeysWith: { _, latest in latest }
            )
            selectedDestinationIDs = selectedDestinationIDs.intersection(
                Set(destinations.filter(\.isReadyForDevelopment).map(\.id))
            )
            appendLog(.info, "Imported \(imported.count) project container(s) from \(parentURL.path). Trust is required per project before xcodebuild operations.")
            operationState = .succeeded
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Import cancelled.")
        } catch {
            presentOperationFailure(UserFacingError.describe(error))
        }
    }

    private func performDestinationRefresh() async {
        var allDestinations: [Destination] = [.localMac]
        var failures: [String] = []

        appendLog(.info, "This Mac is available as a local macOS destination.")

        do {
            let simulators = try await tooling.listSimulators()
            allDestinations.append(contentsOf: simulators)
            appendLog(.info, "simctl found \(simulators.count) available simulator(s).")
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Destination refresh cancelled.")
            return
        } catch {
            let message = UserFacingError.describe(error)
            failures.append("Simulators: \(message)")
            appendLog(.warning, failures.last ?? message)
        }

        do {
            let devices = try await tooling.listPhysicalDevices()
            allDestinations.append(contentsOf: devices)
            appendLog(.info, "devicectl found \(devices.count) physical device(s).")
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Destination refresh cancelled.")
            return
        } catch {
            let message = UserFacingError.describe(error)
            failures.append("Physical devices: \(message)")
            appendLog(.warning, failures.last ?? message)
        }

        destinations = Destination.sorted(allDestinations)
        selectedDestinationIDs = selectedDestinationIDs.intersection(
            Set(destinations.filter(\.isReadyForDevelopment).map(\.id))
        )
        if automaticallySelectRunningDestination, selectedDestinationIDs.isEmpty {
            let preferred = destinations.first {
                $0.kind == .simulator
                    && $0.isReadyForDevelopment
                    && $0.state?.localizedCaseInsensitiveContains("booted") == true
            } ?? destinations.first(where: \.isReadyForDevelopment)
            if let preferred {
                selectedDestinationIDs = [preferred.id]
            }
        }
        var warnings = failures
        let unavailablePhysicalCount = destinations.count {
            $0.kind == .physicalDevice && !$0.isReadyForDevelopment
        }
        if unavailablePhysicalCount > 0 {
            warnings.append("\(unavailablePhysicalCount) physical device(s) remain unavailable after xer asked CoreDevice to prepare them. Unlock and reconnect the device, confirm trust, and enable Developer Mode before refreshing.")
        }
        destinationWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")

        if destinations.isEmpty, !failures.isEmpty {
            presentOperationFailure(failures.joined(separator: "\n"))
        } else {
            operationState = failures.isEmpty ? .succeeded : .failed(failures.joined(separator: "\n"))
        }
    }

    private func performBuildPhase(
        project: ImportedProject,
        scheme: String,
        destinations: [Destination],
        configuration: String,
        cleanBuildFolder: Bool
    ) async -> [BuildOutcome] {
        var outcomes: [BuildOutcome] = []
        var completed = 0

        for batch in destinations.batches(of: Self.maxConcurrentDestinationOperations) {
            let batchOutcomes = await withTaskGroup(of: BuildOutcome.self, returning: [BuildOutcome].self) { group in
                for destination in batch {
                    let handler = outputHandler(
                        label: "build \(destination.name)",
                        buildProgressTotal: destinations.count
                    )
                    group.addTask { [tooling, project, scheme, destination, configuration, cleanBuildFolder, handler] in
                        do {
                            let derivedDataURL = AppPaths.derivedDataURL(
                                projectPath: project.path,
                                scheme: scheme,
                                destinationID: destination.id
                            )
                            if cleanBuildFolder {
                                try? FileManager.default.removeItem(at: derivedDataURL)
                            }
                            let artifact = try await tooling.build(
                                project: project,
                                scheme: scheme,
                                configuration: configuration,
                                destination: destination,
                                derivedDataURL: derivedDataURL,
                                outputHandler: handler
                            )
                            return BuildOutcome(destination: destination, artifact: artifact, errorMessage: nil)
                        } catch {
                            return BuildOutcome(
                                destination: destination,
                                artifact: nil,
                                errorMessage: UserFacingError.describe(error)
                            )
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            outcomes.append(contentsOf: batchOutcomes)
            completed += batch.count
            operationState = .building(completed: completed, total: destinations.count)

            for outcome in batchOutcomes {
                if let error = outcome.errorMessage {
                    appendLog(.error, "Build failed for \(outcome.destination.name): \(error)")
                } else if let artifact = outcome.artifact {
                    latestBuildArtifacts[outcome.destination.id] = artifact
                    appendLog(.info, "Build succeeded for \(outcome.destination.name).")
                }
            }
            if Task.isCancelled { break }
        }
        return outcomes
    }

    private func performBuildAndDeploy(
        project: ImportedProject,
        scheme: String,
        destinations: [Destination],
        configuration: String,
        cleanBuildFolder: Bool,
        attachConsole: Bool,
        includeUnifiedLogs: Bool
    ) async {
        var buildOutcomes: [BuildOutcome] = []
        var completedBuilds = 0

        do {
            for batch in destinations.batches(of: Self.maxConcurrentDestinationOperations) {
                let batchOutcomes = await withTaskGroup(of: BuildOutcome.self, returning: [BuildOutcome].self) { group in
                    for destination in batch {
                        let handler = outputHandler(
                            label: "build \(destination.name)",
                            buildProgressTotal: destinations.count
                        )
                        group.addTask { [tooling, project, scheme, destination, configuration, cleanBuildFolder, handler] in
                            do {
                                let derivedDataURL = AppPaths.derivedDataURL(
                                    projectPath: project.path,
                                    scheme: scheme,
                                    destinationID: destination.id
                                )
                                if cleanBuildFolder {
                                    try? FileManager.default.removeItem(at: derivedDataURL)
                                }
                                let artifact = try await tooling.build(
                                    project: project,
                                    scheme: scheme,
                                    configuration: configuration,
                                    destination: destination,
                                    derivedDataURL: derivedDataURL,
                                    outputHandler: handler
                                )
                                return BuildOutcome(destination: destination, artifact: artifact, errorMessage: nil)
                            } catch {
                                return BuildOutcome(
                                    destination: destination,
                                    artifact: nil,
                                    errorMessage: UserFacingError.describe(error)
                                )
                            }
                        }
                    }

                    var outcomes: [BuildOutcome] = []
                    for await outcome in group {
                        outcomes.append(outcome)
                    }
                    return outcomes
                }
                buildOutcomes.append(contentsOf: batchOutcomes)
                completedBuilds += batch.count
                operationState = .building(completed: completedBuilds, total: destinations.count)

                for outcome in batchOutcomes {
                    if let errorMessage = outcome.errorMessage {
                        appendLog(.error, "Build failed for \(outcome.destination.name): \(errorMessage)")
                    } else {
                        appendLog(.info, "Build succeeded for \(outcome.destination.name).")
                    }
                }
                try Task.checkCancellation()
            }

            let artifacts = buildOutcomes.compactMap(\.artifact)
            for artifact in artifacts {
                latestBuildArtifacts[artifact.destination.id] = artifact
            }
            let buildFailures = buildOutcomes.compactMap { outcome -> String? in
                guard let errorMessage = outcome.errorMessage else { return nil }
                return "\(outcome.destination.name): \(errorMessage)"
            }

            guard !artifacts.isEmpty else {
                presentOperationFailure(buildFailures.joined(separator: "\n"))
                return
            }

            var deployOutcomes: [DeployOutcome] = []
            var completedDeployments = 0
            operationState = .installing(completed: 0, total: artifacts.count)
            for batch in artifacts.batches(of: Self.maxConcurrentDestinationOperations) {
                let batchOutcomes = await withTaskGroup(of: DeployOutcome.self, returning: [DeployOutcome].self) { group in
                    for artifact in batch {
                        let handler = outputHandler(label: "deploy \(artifact.destination.name)")
                        group.addTask { [tooling, artifact, handler] in
                            do {
                                try await tooling.install(artifact: artifact, outputHandler: handler)
                                return DeployOutcome(
                                    destination: artifact.destination,
                                    artifact: artifact,
                                    errorMessage: nil
                                )
                            } catch {
                                return DeployOutcome(
                                    destination: artifact.destination,
                                    artifact: nil,
                                    errorMessage: UserFacingError.describe(error)
                                )
                            }
                        }
                    }

                    var outcomes: [DeployOutcome] = []
                    for await outcome in group {
                        outcomes.append(outcome)
                    }
                    return outcomes
                }
                deployOutcomes.append(contentsOf: batchOutcomes)
                completedDeployments += batch.count
                operationState = .installing(completed: completedDeployments, total: artifacts.count)

                for outcome in batchOutcomes {
                    if let errorMessage = outcome.errorMessage {
                        appendLog(.error, "Install failed for \(outcome.destination.name): \(errorMessage)")
                    } else if let artifact = outcome.artifact {
                        let fallbackApp = InstalledApp(artifact: artifact)
                        installedApps.removeAll { $0.id == fallbackApp.id }
                        installedApps.append(fallbackApp)
                        appendLog(.info, "Installed \(artifact.displayName ?? artifact.appURL.lastPathComponent) on \(outcome.destination.name).")

                        // Fetch a device-generated icon only when the local
                        // product did not expose one. Icon lookup is best effort
                        // and must never block launch or make deployment fail.
                        if artifact.appIcon == nil {
                            let iconHandler = outputHandler(label: "icon \(artifact.destination.name)")
                            Task { [weak self, tooling, artifact, iconHandler] in
                                guard let self else { return }
                                do {
                                    guard let icon = try await tooling.installedAppIcon(
                                        for: artifact,
                                        outputHandler: iconHandler
                                    ) else { return }
                                    await MainActor.run {
                                        guard let index = self.installedApps.firstIndex(where: { $0.id == fallbackApp.id }) else { return }
                                        self.installedApps[index] = InstalledApp(artifact: artifact, icon: icon)
                                    }
                                } catch {
                                    // Icon availability is optional; deployment
                                    // and console streaming continue unchanged.
                                    await MainActor.run {
                                        self.appendLog(.warning, "Could not retrieve the installed app icon for \(artifact.destination.name): \(UserFacingError.describe(error))")
                                    }
                                }
                            }
                        }
                    }
                }
                try Task.checkCancellation()
            }

            let deploymentFailures = deployOutcomes.compactMap { outcome -> String? in
                guard let errorMessage = outcome.errorMessage else { return nil }
                return "\(outcome.destination.name): \(errorMessage)"
            }
            let launchableArtifacts = deployOutcomes.compactMap(\.artifact)
            guard !launchableArtifacts.isEmpty else {
                // Do not enter a streaming phase or claim that console output is
                // attached when every install failed.
                presentOperationFailure((buildFailures + deploymentFailures).joined(separator: "\n"))
                return
            }

            // Launching is intentionally a separate lifecycle phase. The launch
            // commands attach to the app console (`--console`) and therefore
            // must remain awaited; returning immediately here would close the
            // output stream while the selected app is still running.
            operationState = .launching
            appendLog(.info, includeUnifiedLogs
                ? "Launching installed app(s) with standard streams and unified Logger/OSLog forwarding. Stop the app or cancel to end the stream."
                : (attachConsole
                    ? "Launching installed app(s) and attaching standard output. Stop the app or cancel to end the stream."
                    : "Launching installed app(s)."))
            let launchOutcomes = await withTaskGroup(of: LaunchOutcome.self, returning: [LaunchOutcome].self) { group in
                for artifact in launchableArtifacts {
                    let handler = outputHandler(
                        label: "console \(artifact.destination.name)",
                        marksAppRunning: true
                    )
                    group.addTask { [tooling, artifact, handler] in
                        do {
                            try await tooling.launch(
                                artifact: artifact,
                                attachConsole: attachConsole,
                                includeUnifiedLogs: includeUnifiedLogs,
                                outputHandler: handler
                            )
                            return LaunchOutcome(destination: artifact.destination, errorMessage: nil)
                        } catch {
                            return LaunchOutcome(
                                destination: artifact.destination,
                                errorMessage: UserFacingError.describe(error)
                            )
                        }
                    }
                }

                // Console-attached launch commands can remain silent for the
                // entire app session. Reaching this point means every launch
                // has been dispatched, so do not wait for app stdout before
                // reflecting that the app is running.
                operationState = .running

                var outcomes: [LaunchOutcome] = []
                for await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }
            try Task.checkCancellation()

            for outcome in launchOutcomes {
                if let errorMessage = outcome.errorMessage {
                    appendLog(.error, "Launch/console failed for \(outcome.destination.name): \(errorMessage)")
                } else {
                    appendLog(.info, attachConsole
                        ? "App exited on \(outcome.destination.name); console stream closed."
                        : "App launched on \(outcome.destination.name).")
                }
            }

            let launchFailures = launchOutcomes.compactMap { outcome -> String? in
                guard let errorMessage = outcome.errorMessage else { return nil }
                return "\(outcome.destination.name): \(errorMessage)"
            }
            let allFailures = buildFailures + deploymentFailures + launchFailures
            if allFailures.isEmpty {
                operationState = .succeeded
                appendLog(.info, "Build, install, and launch completed for all selected destinations.")
            } else {
                presentOperationFailure(allFailures.joined(separator: "\n"))
            }
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Build/deploy cancelled.")
        } catch {
            presentOperationFailure(UserFacingError.describe(error))
        }
    }

    private func updateProjectSchemes(projectID: String, schemes: [SharedScheme]) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var project = projects[index]
        project.schemes = schemes
        projects[index] = project
        persistProject(project)

        if let selected = selectedSchemeByProject[projectID], schemes.contains(where: { $0.name == selected }) {
            return
        }
        selectedSchemeByProject[projectID] = schemes.first?.name
    }

    private func outputHandler(
        label: String,
        buildProgressTotal: Int? = nil,
        marksAppRunning: Bool = false
    ) -> ProcessRunner.OutputHandler {
        { [weak self] output in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let buildProgressTotal {
                    self.updateBuildPhase(
                        from: output.text,
                        totalDestinations: buildProgressTotal
                    )
                }
                if marksAppRunning,
                   output.stream == .standardOutput,
                   !output.text.xerTrimmed.isEmpty,
                   self.operationState == .launching {
                    self.operationState = .running
                }
                let level: LogEntry.Level = output.stream == .standardError ? .warning : .info
                // Preserve chunk boundaries and whitespace. Pipe reads are not
                // guaranteed to end on line boundaries; trimming every chunk
                // can concatenate a trailing partial line with the next chunk.
                self.appendLog(level, "[\(label)] \(output.text)", preserveWhitespace: true)
            }
        }
    }

    private func updateBuildPhase(from output: String, totalDestinations: Int) {
        guard operationState == .preparingBuild else { return }
        let buildWorkMarkers = [
            "CompileSwift",
            "SwiftCompile",
            "CompileC",
            "Ld ",
            "PhaseScriptExecution",
            "ProcessInfoPlistFile",
            "Copy ",
            "CodeSign ",
            "Touch "
        ]
        guard buildWorkMarkers.contains(where: output.contains) else { return }
        operationState = .building(completed: 0, total: totalDestinations)
    }

    private func persistProject(_ project: ImportedProject) {
        guard bookmarkStore.saveProject(project) else {
            appendLog(.warning, "Could not persist a security-scoped bookmark for \(project.displayName). The project may need to be imported again after restarting xer.")
            return
        }
    }

    private func refreshProjectIcons(for projects: [ImportedProject]) {
        projectIconTask?.cancel()
        projectIcons = [:]
        guard !projects.isEmpty else { return }

        let discovery = discovery
        projectIconTask = Task { @MainActor [weak self] in
            let discoveryTask = Task.detached(priority: .utility) {
                var icons: [String: AppIcon] = [:]
                for project in projects {
                    guard !Task.isCancelled else { break }
                    if let icon = discovery.appIcon(in: project.url) {
                        icons[project.id] = icon
                    }
                }
                return icons
            }
            let icons = await withTaskCancellationHandler {
                await discoveryTask.value
            } onCancel: {
                discoveryTask.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.projectIcons = icons
            self?.projectIconTask = nil
        }
    }

    private func commandDescription(_ arguments: [String]) -> String {
        ProcessRunner.displayCommand(
            executableURL: DeveloperTooling.executableURL,
            arguments: arguments
        )
    }

    private func appendLog(
        _ level: LogEntry.Level,
        _ message: String,
        preserveWhitespace: Bool = false
    ) {
        let normalizedMessage = preserveWhitespace ? message : message.xerTrimmed
        let entry = LogEntry(level: level, message: normalizedMessage)
        logs.append(entry)
        if logs.count > 4_000 {
            logs.removeFirst(logs.count - 4_000)
        }
    }

    private func presentError(_ message: String) {
        lastErrorMessage = message
        appendLog(.error, message)
    }

    private func presentOperationFailure(_ message: String) {
        let normalized = message.xerTrimmed.isEmpty ? "The operation failed without a diagnostic." : message.xerTrimmed
        lastErrorMessage = normalized
        operationState = .failed(normalized)
        appendLog(.error, normalized)
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct BuildContext: Sendable {
    let project: ImportedProject
    let scheme: String
    let destinations: [Destination]
    let configuration: String
    let cleanBuildFolder: Bool
}

private struct BuildOutcome: Sendable {
    let destination: Destination
    let artifact: BuildArtifact?
    let errorMessage: String?
}

private struct DeployOutcome: Sendable {
    let destination: Destination
    let artifact: BuildArtifact?
    let errorMessage: String?
}

private struct LaunchOutcome: Sendable {
    let destination: Destination
    let errorMessage: String?
}

enum AppPaths {
    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xer", isDirectory: true)
    }

    static var derivedDataRoot: URL {
        applicationSupportRoot.appendingPathComponent("DerivedData", isDirectory: true)
    }

    static func derivedDataURL(projectPath: String, scheme: String, destinationID: String) -> URL {
        derivedDataRoot
            .appendingPathComponent(stableComponent(projectPath), isDirectory: true)
            .appendingPathComponent(stableComponent(scheme), isDirectory: true)
            .appendingPathComponent(stableComponent(destinationID), isDirectory: true)
    }

    private static func stableComponent(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum UserFacingError {
    static func describe(_ error: Error) -> String {
        if error is CancellationError {
            return "Cancelled."
        }

        if let failure = error as? ToolFailure {
            let output = failure.output.xerTrimmed
            let lowercased = output.lowercased()
            if lowercased.contains("code signing")
                || lowercased.contains("codesign")
                || lowercased.contains("provisioning profile")
                || lowercased.contains("signing certificate")
                || lowercased.contains("no profiles") {
                return "Xcode could not sign this build. xer leaves signing enabled and does not weaken or bypass provisioning. Check the selected team, profile, certificate, device registration, and Developer Mode.\n\(tail(of: output))"
            }
            if lowercased.contains("developer mode")
                || lowercased.contains("trust this computer")
                || lowercased.contains("pair") {
                return "The connected device is not ready for developer operations. Confirm pairing/trust and enable Developer Mode if required.\n\(tail(of: output))"
            }
            if lowercased.contains("cannot be used within an app sandbox") {
                return "This build of xer is still running with App Sandbox enabled. Rebuild the xer target with ENABLE_APP_SANDBOX=NO; xcrun and xcodebuild cannot run from a sandboxed developer utility.\n\(tail(of: output))"
            }
            if lowercased.contains("unable to find utility")
                || lowercased.contains("command not found")
                || lowercased.contains("no such file or directory") {
                return "The Xcode command-line developer tools are unavailable. Install/select Xcode in Xcode > Settings > Locations, then retry.\n\(tail(of: output))"
            }
            return tail(of: output.isEmpty ? (failure.underlyingMessage ?? failure.localizedDescription) : output)
        }

        return error.localizedDescription.xerTrimmed
    }

    private static func tail(of text: String) -> String {
        let limit = 3_000
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit)
    }
}

private extension Array {
    func batches(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var batches: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            batches.append(Array(self[index..<end]))
            index = end
        }
        return batches
    }
}
