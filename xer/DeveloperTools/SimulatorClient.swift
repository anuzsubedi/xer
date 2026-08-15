import AppKit
import Foundation

extension DeveloperTooling {

    func listSimulators(
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> [Destination] {
        let arguments = Self.simulatorListArguments()
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        guard let object = Self.jsonObject(from: result.stdout) else {
            throw AppFailure(message: "simctl returned an unreadable simulator list.")
        }
        return try Self.simulatorDestinations(from: object)
    }

    @MainActor
    func activateSimulator(for destination: Destination) async throws {
        guard let simulatorURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ) else {
            throw AppFailure(message: "Simulator.app could not be found.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = true
        // When Simulator is not already running, this selects the exact device
        // xer is about to launch onto. If it is running, Launch Services still
        // activates its existing instance so the device window becomes visible.
        configuration.arguments = ["-CurrentDeviceUDID", destination.udid]

        _ = try await NSWorkspace.shared.openApplication(
            at: simulatorURL,
            configuration: configuration
        )
    }
}
