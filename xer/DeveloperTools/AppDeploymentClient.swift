import AppKit
import Foundation

extension DeveloperTooling {

    /// Installs the artifact but deliberately does not launch it. Keeping the
    /// phases separate lets the model publish installed-app metadata (including
    /// its icon) before the potentially long-lived console launch begins.
    func install(
        artifact: BuildArtifact,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws {
        try validate(artifact)

        let arguments: [String]
        switch artifact.destination.kind {
        case .localMac:
            // The built product already lives on this Mac; there is no device
            // installation phase to perform.
            return
        case .simulator:
            try await bootSimulatorIfNeeded(artifact.destination, outputHandler: outputHandler)
            arguments = Self.simulatorInstallArguments(for: artifact)
        case .physicalDevice:
            // devicectl is the supported CoreDevice command-line interface for
            // installing on a connected physical device.
            arguments = Self.physicalDeviceInstallArguments(for: artifact)
        }

        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)
    }

    /// Launches an installed device artifact or a locally built Mac artifact and
    /// keeps the process attached until the app exits or the operation is cancelled.
    func launch(
        artifact: BuildArtifact,
        attachConsole: Bool = true,
        includeUnifiedLogs: Bool = false,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws {
        try validate(artifact)

        if artifact.destination.kind == .localMac {
            let executableURL = try Self.localMacExecutableURL(for: artifact.appURL)
            let result = try await processRunner.run(
                executableURL: executableURL,
                arguments: [],
                outputHandler: outputHandler
            )
            try check(
                result,
                executableURL: executableURL,
                arguments: []
            )
            return
        }

        let arguments: [String]
        switch artifact.destination.kind {
        case .localMac:
            preconditionFailure("Handled above")
        case .simulator:
            arguments = Self.simulatorLaunchArguments(for: artifact, attachConsole: attachConsole)
        case .physicalDevice:
            arguments = Self.physicalDeviceLaunchArguments(
                for: artifact,
                attachConsole: attachConsole,
                includeUnifiedLogs: includeUnifiedLogs
            )
        }

        let environment: [String: String]? = artifact.destination.kind == .simulator && includeUnifiedLogs
            ? ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "YES"]
            : nil

        if artifact.destination.kind == .simulator {
            do {
                try await activateSimulator(for: artifact.destination)
            } catch {
                // Showing Simulator is a convenience, not part of deployment.
                // Keep the app launch working if Launch Services cannot present
                // the window, but make the recovery path visible in the console.
                outputHandler?(ProcessOutput(
                    stream: .standardError,
                    text: "Simulator could not be brought forward: \(error.localizedDescription)\n"
                ))
            }
        }

        let result = try await invoke(
            arguments,
            environment: environment,
            outputHandler: outputHandler
        )
        try check(result, arguments: arguments)
    }

    /// Compatibility/convenience entry point for callers that do not need the
    /// install/launch boundary. `launch` remains attached to the app console.
    func installAndLaunch(
        artifact: BuildArtifact,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws {
        try await install(artifact: artifact, outputHandler: outputHandler)
        try await launch(artifact: artifact, outputHandler: outputHandler)
    }
}
