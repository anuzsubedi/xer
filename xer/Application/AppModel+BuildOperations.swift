import AppKit
import Foundation

extension AppModel {

    func runOrRestart() {
        guard canRunOrRestart else { return }
        guard let activeTask = operationTask else {
            buildInstallAndLaunchSelected()
            return
        }

        appendLog(.command, "Run requested while the app is active. Stopping it before rebuilding, installing, and relaunching.")
        activeTask.cancel()
        tooling.cancelAll()

        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await activeTask.value
            guard !Task.isCancelled else {
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

        lastIssue = nil
        operationState = .refreshingSchemes
        appendLog(.command, commandDescription(DeveloperTooling.schemeListArguments(for: project)))

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSchemesFromXcodebuild(presentFailures: true)
            await self.refreshSchemeCompatibleDestinations()
            if self.operationState == .refreshingSchemes {
                self.operationState = .succeeded
            }
            self.operationTask = nil
        }
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
        Task { await refreshSchemeCompatibleDestinations() }
    }

    func selectBuildConfiguration(_ configuration: String) {
        guard ["Debug", "Release"].contains(configuration) else { return }
        buildConfiguration = configuration
        latestBuildArtifacts.removeAll()
    }

    func buildSelected() {
        guard !isBusy else { return }
        lastIssue = nil
        installedApps.removeAll()
        latestBuildArtifacts.removeAll()
        operationState = .preparingBuild

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSchemeCompatibleDestinations()
            guard let context = self.validatedBuildContext(requireIdle: false) else {
                if self.operationState == .preparingBuild {
                    self.operationState = .idle
                }
                self.operationTask = nil
                return
            }
            self.appendLog(.command, "Building \(context.scheme) for \(context.destinations.count) destination(s).")
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
                        group.addTask { [buildCoordinator = self.buildCoordinator, artifact, handler] in
                            do {
                                try await buildCoordinator.install(artifact: artifact, outputHandler: handler)
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
            presentError("Select This Mac, a simulator, or a connected device that this scheme can run on.")
            return
        }

        lastIssue = nil
        installedApps.removeAll()
        let configuration = buildConfiguration
        let shouldCleanBuildFolder = cleanBuildFolder
        let shouldAttachConsole = openConsoleForOutput
        let shouldIncludeUnifiedLogs = includeUnifiedLogs
        operationState = .preparingBuild
        appendLog(.command, "Starting bounded build/deploy, max concurrency \(Self.maxConcurrentDestinationOperations).")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSchemeCompatibleDestinations()
            guard let context = self.validatedBuildContext(requireIdle: false) else {
                if self.operationState == .preparingBuild {
                    self.operationState = .idle
                }
                self.operationTask = nil
                return
            }
            self.appendLog(.command, "Using \(context.destinations.count) destination(s) compatible with \(context.scheme).")
            for destination in context.destinations {
                let derivedDataURL = AppPaths.derivedDataURL(
                    projectPath: context.project.path,
                    scheme: context.scheme,
                    destinationID: destination.id
                )
                self.appendLog(.command, self.commandDescription(DeveloperTooling.buildArguments(
                    for: context.project,
                    scheme: context.scheme,
                    configuration: configuration,
                    destination: destination,
                    derivedDataURL: derivedDataURL
                )))
            }
            await self.performBuildAndDeploy(
                project: context.project,
                scheme: context.scheme,
                destinations: context.destinations,
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
        operationController.cancel(using: tooling)
    }

    func validatedBuildContext(requireIdle: Bool = true) -> BuildContext? {
        guard !requireIdle || !isBusy else { return nil }
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
        let destinations = selectedDestinations.filter(isCompatibleWithSelectedScheme)
        guard !destinations.isEmpty else {
            presentError("Select This Mac, a simulator, or a connected device that this scheme can run on.")
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

}
