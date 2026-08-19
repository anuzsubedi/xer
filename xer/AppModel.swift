import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let maxConcurrentDestinationOperations = 2

    @Published var projectStore = ProjectStore()
    @Published var destinationStore = DestinationStore()
    @Published var logStore = LogStore()
    @Published var operationState: AppOperationState = .idle
    @Published var installedApps: [InstalledApp] = []
    @Published var buildConfiguration = "Debug"
    @Published var cleanBuildFolder = false
    @Published var openConsoleForOutput = true
    @Published var includeUnifiedLogs = false
    @Published var automaticallySelectRunningDestination = false
    @Published var lastIssue: OperationIssue?

    let tooling: DeveloperTooling
    let buildCoordinator: BuildCoordinator
    let discovery: ProjectDiscovery
    let bookmarkStore: BookmarkStore
    var projectScopes: [String: SecurityScopeAccess] = [:]
    var parentScope: SecurityScopeAccess?
    let operationController = OperationController()
    var projectIconTask: Task<Void, Never>?
    var schemeDestinationTask: Task<Void, Never>?
    var latestBuildArtifacts: [String: BuildArtifact] = [:]
    var hasRestored = false

    init(
        tooling: DeveloperTooling = DeveloperTooling(),
        discovery: ProjectDiscovery = ProjectDiscovery(),
        bookmarkStore: BookmarkStore = BookmarkStore()
    ) {
        self.tooling = tooling
        self.buildCoordinator = BuildCoordinator(tooling: tooling)
        self.discovery = discovery
        self.bookmarkStore = bookmarkStore
    }

    var operationTask: Task<Void, Never>? {
        get { operationController.activeTask }
        set { operationController.activeTask = newValue }
    }

    var restartTask: Task<Void, Never>? {
        get { operationController.restartTask }
        set { operationController.restartTask = newValue }
    }

    var isBusy: Bool { operationController.isBusy }
    var canStop: Bool { isBusy }

    var projects: [ImportedProject] {
        get { projectStore.projects }
        set { projectStore.projects = newValue }
    }

    var parentFolderURL: URL? {
        get { projectStore.parentFolderURL }
        set { projectStore.parentFolderURL = newValue }
    }

    var projectIcons: [String: AppIcon] {
        get { projectStore.projectIcons }
        set { projectStore.projectIcons = newValue }
    }

    var selectedProjectID: String? {
        get { projectStore.selectedProjectID }
        set { projectStore.selectedProjectID = newValue }
    }

    var selectedSchemeByProject: [String: String] {
        get { projectStore.selectedSchemeByProject }
        set { projectStore.selectedSchemeByProject = newValue }
    }

    var destinations: [Destination] {
        get { destinationStore.destinations }
        set { destinationStore.destinations = newValue }
    }

    var destinationWarning: String? {
        get { destinationStore.warning }
        set { destinationStore.warning = newValue }
    }

    var destinationSearchQuery: String {
        get { destinationStore.searchQuery }
        set { destinationStore.searchQuery = newValue }
    }

    var schemeCompatibleDestinationIDs: Set<String>? {
        get { destinationStore.schemeCompatibleIDs }
        set { destinationStore.schemeCompatibleIDs = newValue }
    }

    var schemeDestinationNote: String? {
        get { destinationStore.schemeDestinationNote }
        set { destinationStore.schemeDestinationNote = newValue }
    }

    var selectedDestinationIDs: Set<String> {
        get { destinationStore.selectedIDs }
        set { destinationStore.selectedIDs = newValue }
    }

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
        Destination.sorted(destinations.filter {
            $0.isReadyForDevelopment
                && selectedDestinationIDs.contains($0.id)
                && isCompatibleWithSelectedScheme($0)
        })
    }

    var logs: [LogEntry] { logStore.entries }
    var lastErrorMessage: String? { lastIssue?.message }

    /// Model-layer destination filtering used by any future presentation. The
    /// query is tokenized, case/diacritic-insensitive, and matches names,
    /// platform, OS, identifiers, and status aliases.
    var filteredDestinations: [Destination] {
        Destination.sorted(destinations.filter {
            $0.matchesSearch(destinationSearchQuery) && isCompatibleWithSelectedScheme($0)
        })
    }

    func isCompatibleWithSelectedScheme(_ destination: Destination) -> Bool {
        guard let schemeCompatibleDestinationIDs else { return true }
        return schemeCompatibleDestinationIDs.contains(destination.id)
    }

    var connectedDestinations: [Destination] {
        filteredDestinations.filter { $0.kind == .physicalDevice && $0.isConnected }
    }

    var otherDestinations: [Destination] {
        filteredDestinations.filter { !($0.kind == .physicalDevice && $0.isConnected) }
    }

    var logText: String { logStore.text }

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

}
