import AppKit
import Foundation

extension AppModel {

    func projectIcon(for project: ImportedProject) -> AppIcon? {
        projectIcons[project.id]
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

            let diskSchemes = discovery.sharedSchemes(in: normalizedURL)
            let schemes = mergedSchemes(diskSchemes, persisted: record.schemes)
            let project = ImportedProject(
                path: normalizedURL.path,
                kind: resolvedKind,
                schemes: schemes,
                isTrusted: record.isTrusted,
                parentPath: record.parentPath
            )
            restoredProjects.append(project)
            scopes[project.path] = scope
            if schemes != record.schemes {
                persistProject(project)
            }
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
            Task { await loadSchemesForSelectedProjectIfNeeded() }
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

        lastIssue = nil
        operationState = .importing
        appendLog(.command, "Inspecting imported folder \(normalizedURL.path)")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performImport(from: normalizedURL)
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
        reloadSchemesFromDisk(projectID: projectID)
        Task { await loadSchemesForSelectedProjectIfNeeded() }
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
        if let projectID {
            reloadSchemesFromDisk(projectID: projectID)
        }
        Task { await loadSchemesForSelectedProjectIfNeeded() }
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

    func performImport(from parentURL: URL) async {
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
                let schemes = mergedSchemes(
                    discoveredSchemes[path] ?? [],
                    persisted: previous?.schemes ?? stored?.schemes ?? []
                )
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
                    appendLog(.warning, "\(project.displayName) has no scheme files on disk. Trust it so xer can load Xcode’s scheme list.")
                } else {
                    appendLog(.info, "Discovered \(schemes.count) scheme(s) in \(project.displayName) without executing project build phases.")
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
            await loadSchemesForSelectedProjectIfNeeded()
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Import cancelled.")
        } catch {
            presentOperationFailure(UserFacingError.describe(error))
        }
    }

    func reloadSchemesFromDisk(projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        let merged = mergedSchemes(
            discovery.sharedSchemes(in: project.url),
            persisted: project.schemes
        )
        guard merged != project.schemes else { return }
        updateProjectSchemes(projectID: projectID, schemes: merged)
        if merged.isEmpty {
            appendLog(.warning, "\(project.displayName) still has no scheme files on disk.")
        } else {
            appendLog(.info, "Loaded \(merged.count) scheme(s) for \(project.displayName) from disk.")
        }
    }

    func loadSchemesForSelectedProjectIfNeeded() async {
        guard let project = selectedProject else {
            schemeCompatibleDestinationIDs = nil
            schemeDestinationNote = nil
            return
        }

        reloadSchemesFromDisk(projectID: project.id)
        if project.isTrusted, selectedProject?.schemes.isEmpty == true, !isBusy {
            await refreshSchemesFromXcodebuild()
        }
        await refreshSchemeCompatibleDestinations()
    }

    func refreshSchemesFromXcodebuild(presentFailures: Bool = false) async {
        guard let project = selectedProject, project.isTrusted else { return }
        do {
            appendLog(.command, "Loading schemes for \(project.displayName) with xcodebuild.")
            let handler = outputHandler(label: "schemes \(project.displayName)")
            let schemes = try await tooling.listSchemes(for: project, outputHandler: handler)
            updateProjectSchemes(projectID: project.id, schemes: schemes)
            if schemes.isEmpty {
                appendLog(.warning, "No schemes were returned for \(project.displayName).")
            } else {
                appendLog(.info, "Found \(schemes.count) scheme(s) for \(project.displayName).")
            }
        } catch is CancellationError {
            appendLog(.warning, "Scheme refresh cancelled.")
        } catch {
            let message = UserFacingError.describe(error)
            if presentFailures {
                presentOperationFailure(message)
            } else {
                appendLog(.warning, "Could not load schemes for \(project.displayName): \(message)")
            }
        }
    }

    func mergedSchemes(_ disk: [SharedScheme], persisted: [SharedScheme]) -> [SharedScheme] {
        var names = Set(disk.map(\.name))
        names.formUnion(persisted.map(\.name))
        return names
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(SharedScheme.init(name:))
    }

    func updateProjectSchemes(projectID: String, schemes: [SharedScheme]) {
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

    func persistProject(_ project: ImportedProject) {
        guard bookmarkStore.saveProject(project) else {
            appendLog(.warning, "Could not persist a security-scoped bookmark for \(project.displayName). The project may need to be imported again after restarting xer.")
            return
        }
    }

    func refreshProjectIcons(for projects: [ImportedProject]) {
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
}
