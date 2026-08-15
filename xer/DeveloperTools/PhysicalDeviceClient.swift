import AppKit
import Foundation

extension DeveloperTooling {

    /// devicectl's JSON file is its supported machine-readable interface. The
    /// human table printed by `devicectl list devices` is intentionally not
    /// parsed because Apple does not promise its formatting.
    func listPhysicalDevices(
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> [Destination] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var destinations = try await readPhysicalDevices(
            jsonURL: temporaryDirectory.appendingPathComponent("devices.json"),
            outputHandler: outputHandler
        )

        // A plain device list can report a recently connected phone as
        // unavailable until something asks CoreDevice to establish its tunnel
        // and prepare developer services. Xcode performs that handshake as a
        // side effect of opening an iOS project. Do the supported CLI equivalent
        // here so xer does not depend on Xcode already being open.
        let unavailableDevices = destinations.filter {
            $0.kind == .physicalDevice && !$0.isReadyForDevelopment
        }
        if !unavailableDevices.isEmpty {
            for (index, destination) in unavailableDevices.enumerated() {
                try Task.checkCancellation()
                let detailsURL = temporaryDirectory
                    .appendingPathComponent("device-details-\(index).json")
                let arguments = Self.physicalDeviceDetailsArguments(
                    deviceID: destination.udid,
                    jsonURL: detailsURL
                )
                // This is best effort. A genuinely unpaired, disconnected, or
                // Developer-Mode-disabled device should remain visible with its
                // original diagnostic instead of failing the whole refresh.
                _ = try? await invoke(arguments, outputHandler: outputHandler)
            }

            destinations = try await readPhysicalDevices(
                jsonURL: temporaryDirectory.appendingPathComponent("devices-refreshed.json"),
                outputHandler: outputHandler
            )
        }

        return destinations
    }

    func readPhysicalDevices(
        jsonURL: URL,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws -> [Destination] {
        let arguments = Self.physicalDeviceListArguments(jsonURL: jsonURL)
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        guard let data = try? Data(contentsOf: jsonURL),
              let object = Self.jsonObject(from: data) else {
            throw AppFailure(message: "devicectl returned an unreadable connected-device list.")
        }
        return try Self.physicalDestinations(from: object)
    }

    /// Best-effort retrieval of the icon from a physical device after install.
    /// The local build icon remains the fallback when the device cannot provide
    /// one (for example on an older CoreDevice implementation).
    func installedAppIcon(
        for artifact: BuildArtifact,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> AppIcon? {
        // Prefer the icon embedded in the built product. Device retrieval is a
        // fallback for bundles whose icon only exists in a device-side asset
        // catalog.
        guard artifact.appIcon == nil,
              artifact.destination.kind == .physicalDevice else {
            return artifact.appIcon
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-app-icon-\(UUID().uuidString)", isDirectory: true)
        let iconURL = temporaryDirectory.appendingPathComponent("icon.png")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let arguments = Self.physicalDeviceAppIconArguments(
            for: artifact,
            destinationURL: iconURL
        )
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        guard let data = try? Data(contentsOf: iconURL), !data.isEmpty else {
            return artifact.appIcon
        }
        return AppIcon(data: data)
    }
}
