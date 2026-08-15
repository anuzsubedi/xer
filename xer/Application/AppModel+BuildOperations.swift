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

    func buildSelected() {
        guard let context = validatedBuildContext() else { return }
        lastIssue = nil
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
            presentError("Select at least one simulator or connected device.")
            return
        }

        lastIssue = nil
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
        operationController.cancel(using: tooling)
    }

    func validatedBuildContext() -> BuildContext? {
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

}
