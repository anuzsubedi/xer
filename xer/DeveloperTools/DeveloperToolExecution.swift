import Foundation

extension DeveloperTooling {
    func validate(_ artifact: BuildArtifact) throws {
        guard FileManager.default.fileExists(atPath: artifact.appURL.path) else {
            throw AppFailure(message: "The built app bundle no longer exists at \(artifact.appURL.path).")
        }
        guard !artifact.bundleIdentifier.xerTrimmed.isEmpty else {
            throw AppFailure(message: "The built app has no bundle identifier and cannot be launched.")
        }
        guard artifact.destination.isAvailable else {
            throw AppFailure(message: "The destination is no longer available for install or launch.")
        }
    }

    func bootSimulatorIfNeeded(
        _ destination: Destination,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws {
        let normalizedState = destination.state?.lowercased() ?? ""
        if !normalizedState.contains("boot") {
            let bootArguments = ["simctl", "boot", destination.udid]
            let bootResult = try await invoke(bootArguments, outputHandler: outputHandler)
            if !bootResult.succeeded {
                let output = bootResult.combinedOutput.lowercased()
                let alreadyBooted = output.contains("already booted")
                    || output.contains("current state: booted")
                    || output.contains("is booted")
                guard alreadyBooted else {
                    try check(bootResult, arguments: bootArguments)
                    return
                }
            }
        }

        // Wait even when discovery reported Booted: the state can change between
        // discovery and deployment.
        let bootStatusArguments = ["simctl", "bootstatus", destination.udid, "-b"]
        let bootStatusResult = try await invoke(bootStatusArguments, outputHandler: outputHandler)
        try check(bootStatusResult, arguments: bootStatusArguments)
    }

    func invoke(
        _ arguments: [String],
        environment: [String: String]? = nil,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws -> ProcessResult {
        do {
            return try await processRunner.run(
                executableURL: xcrunURL,
                arguments: arguments,
                environment: environment,
                outputHandler: outputHandler
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolFailure(
                command: ProcessRunner.displayCommand(executableURL: xcrunURL, arguments: arguments),
                status: nil,
                output: "",
                underlyingMessage: error.localizedDescription
            )
        }
    }

    func check(_ result: ProcessResult, arguments: [String]) throws {
        try check(result, executableURL: xcrunURL, arguments: arguments)
    }

    func check(
        _ result: ProcessResult,
        executableURL: URL,
        arguments: [String]
    ) throws {
        guard !result.succeeded else { return }
        throw ToolFailure(
            command: ProcessRunner.displayCommand(executableURL: executableURL, arguments: arguments),
            status: result.terminationStatus,
            output: result.combinedOutput,
            underlyingMessage: nil
        )
    }

    func findBuiltApplication(in derivedDataURL: URL, preferredName: String) throws -> URL {
        let productsURL = derivedDataURL.appendingPathComponent("Build/Products", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: productsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AppFailure(message: "The build succeeded, but its Products directory was not found at \(productsURL.path).")
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard (try? Self.bundleIdentifier(for: url)) != nil else { continue }
            candidates.append(url)
        }

        guard !candidates.isEmpty else {
            throw AppFailure(message: "The build completed but did not produce an .app bundle for scheme \(preferredName).")
        }

        let preferred = candidates.filter {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(preferredName) == .orderedSame
        }
        if preferred.count == 1 { return preferred[0] }
        if candidates.count == 1 { return candidates[0] }

        let names = candidates.map(\.path).sorted().joined(separator: ", ")
        throw AppFailure(message: "The build produced multiple app bundles and xer could not identify the launchable one: \(names)")
    }

    static func isUsableDevice(
        connectionState: String?,
        pairingState: String?,
        developerMode: String?
    ) -> Bool {
        let unavailableStates = Set([
            "disconnected", "offline", "unavailable", "not connected", "notconnected",
            "unpaired", "pairing required", "pairingrequired", "disabled", "not enabled", "notenabled",
            "developermodedisabled", "developermodenotenabled"
        ])
        let values = [connectionState, pairingState, developerMode]
            .compactMap { $0?.lowercased() }
            .map {
                $0.replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
            }
        return !values.contains(where: { unavailableStates.contains($0) })
    }

    static func runtimeInformation(from identifier: String) -> RuntimeInformation {
        let normalized = identifier
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        let pieces = normalized.split(separator: "-")
        guard let first = pieces.first else {
            return RuntimeInformation(platform: "Simulator", version: nil)
        }
        let platform = String(first)
        let version = pieces.dropFirst().map(String.init).joined(separator: ".")
        return RuntimeInformation(platform: platform, version: version.isEmpty ? nil : version)
    }

    static func deduplicated(_ destinations: [Destination]) -> [Destination] {
        var seen = Set<String>()
        return Destination.sorted(
            destinations.filter { seen.insert($0.id).inserted }
        )
    }
}
