import AppKit
import Foundation

extension AppModel {

    func performBuildPhase(
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
                    group.addTask { [buildCoordinator = self.buildCoordinator, project, scheme, destination, configuration, cleanBuildFolder, handler] in
                        do {
                            let derivedDataURL = AppPaths.derivedDataURL(
                                projectPath: project.path,
                                scheme: scheme,
                                destinationID: destination.id
                            )
                            if cleanBuildFolder {
                                try? FileManager.default.removeItem(at: derivedDataURL)
                            }
                            let artifact = try await buildCoordinator.build(
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

    func performBuildAndDeploy(
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
                        group.addTask { [buildCoordinator = self.buildCoordinator, project, scheme, destination, configuration, cleanBuildFolder, handler] in
                            do {
                                let derivedDataURL = AppPaths.derivedDataURL(
                                    projectPath: project.path,
                                    scheme: scheme,
                                    destinationID: destination.id
                                )
                                if cleanBuildFolder {
                                    try? FileManager.default.removeItem(at: derivedDataURL)
                                }
                                let artifact = try await buildCoordinator.build(
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
                        group.addTask { [buildCoordinator = self.buildCoordinator, artifact, handler] in
                            do {
                                try await buildCoordinator.install(artifact: artifact, outputHandler: handler)
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
                    group.addTask { [buildCoordinator = self.buildCoordinator, artifact, handler] in
                        do {
                            try await buildCoordinator.launch(
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

    func outputHandler(
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

    func updateBuildPhase(from output: String, totalDestinations: Int) {
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

    func commandDescription(_ arguments: [String]) -> String {
        ProcessRunner.displayCommand(
            executableURL: DeveloperTooling.executableURL,
            arguments: arguments
        )
    }
}
