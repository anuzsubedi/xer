import AppKit
import Foundation

/// The command-line surface used by xer. Apple developer commands are sent to
/// xcrun and local Mac apps are launched from their bundle executable. Every
/// invocation uses an argv array; no shell parses paths or scheme names.
final class DeveloperTooling: @unchecked Sendable {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    private let processRunner: ProcessRunner
    private let xcrunURL: URL

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        xcrunURL: URL = DeveloperTooling.executableURL
    ) {
        self.processRunner = processRunner
        self.xcrunURL = xcrunURL
    }

    func listSchemes(
        for project: ImportedProject,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> [SharedScheme] {
        let arguments = Self.schemeListArguments(for: project)
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        guard let object = Self.jsonObject(from: result.stdout) else {
            throw AppFailure(message: "xcodebuild returned an unreadable scheme list for \(project.displayName).")
        }

        return Self.schemeNames(in: object)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(SharedScheme.init(name:))
    }

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

    private func readPhysicalDevices(
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

    func build(
        project: ImportedProject,
        scheme: String,
        configuration: String,
        destination: Destination,
        derivedDataURL: URL,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> BuildArtifact {
        try Task.checkCancellation()

        guard !scheme.xerTrimmed.isEmpty else {
            throw AppFailure(message: "Choose a scheme before building.")
        }
        guard destination.isAvailable else {
            throw AppFailure(message: "The selected destination is not currently available.")
        }
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw AppFailure(message: "The imported project no longer exists at \(project.path).")
        }

        try FileManager.default.createDirectory(
            at: derivedDataURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let arguments = Self.buildArguments(
            for: project,
            scheme: scheme,
            configuration: configuration,
            destination: destination,
            derivedDataURL: derivedDataURL
        )
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        let appURL = try findBuiltApplication(
            in: derivedDataURL,
            preferredName: scheme
        )
        let metadata = try Self.localAppMetadata(for: appURL)
        return BuildArtifact(
            appURL: appURL,
            bundleIdentifier: metadata.bundleIdentifier,
            destination: destination,
            displayName: metadata.displayName,
            appIcon: metadata.icon
        )
    }

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

    func cancelAll() {
        processRunner.cancelAll()
    }

    // MARK: - Command construction

    static func schemeListArguments(for project: ImportedProject) -> [String] {
        ["xcodebuild", "-list", "-json"] + containerArguments(for: project)
    }

    static func simulatorListArguments() -> [String] {
        ["simctl", "list", "devices", "available", "--json"]
    }

    static func physicalDeviceListArguments(jsonURL: URL) -> [String] {
        [
            "devicectl", "--timeout", "15", "list", "devices",
            "--json-output", jsonURL.path
        ]
    }

    static func physicalDeviceDetailsArguments(deviceID: String, jsonURL: URL) -> [String] {
        [
            "devicectl", "--timeout", "30", "device", "info", "details",
            "--device", deviceID,
            "--json-output", jsonURL.path
        ]
    }

    static func buildArguments(
        for project: ImportedProject,
        scheme: String,
        configuration: String,
        destination: Destination,
        derivedDataURL: URL
    ) -> [String] {
        ["xcodebuild"]
            + containerArguments(for: project)
            + [
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", destination.xcodebuildSpecifier,
                "-derivedDataPath", derivedDataURL.path,
                "build"
            ]
    }

    static func simulatorInstallArguments(for artifact: BuildArtifact) -> [String] {
        ["simctl", "install", artifact.destination.udid, artifact.appURL.path]
    }

    static func simulatorLaunchArguments(for artifact: BuildArtifact) -> [String] {
        simulatorLaunchArguments(for: artifact, attachConsole: true)
    }

    static func simulatorLaunchArguments(for artifact: BuildArtifact, attachConsole: Bool) -> [String] {
        // `--console` is important: without it simctl exits as soon as the app
        // is spawned, which tears down xer's output pipe before app logs arrive.
        ["simctl", "launch"]
            + (attachConsole ? ["--console"] : [])
            + [artifact.destination.udid, artifact.bundleIdentifier]
    }

    static func simulatorInstallLaunchArguments(for artifact: BuildArtifact) -> [[String]] {
        [
            simulatorInstallArguments(for: artifact),
            simulatorLaunchArguments(for: artifact)
        ]
    }

    static func physicalDeviceInstallArguments(for artifact: BuildArtifact) -> [String] {
        [
            "devicectl", "--timeout", "120", "device", "install", "app",
            "--device", artifact.destination.udid, artifact.appURL.path
        ]
    }

    static func physicalDeviceLaunchArguments(for artifact: BuildArtifact) -> [String] {
        physicalDeviceLaunchArguments(for: artifact, attachConsole: true)
    }

    static func physicalDeviceLaunchArguments(for artifact: BuildArtifact, attachConsole: Bool) -> [String] {
        physicalDeviceLaunchArguments(
            for: artifact,
            attachConsole: attachConsole,
            includeUnifiedLogs: false
        )
    }

    static func physicalDeviceLaunchArguments(
        for artifact: BuildArtifact,
        attachConsole: Bool,
        includeUnifiedLogs: Bool
    ) -> [String] {
        // Do not put a finite timeout on a console-attached launch. devicectl
        // waits for the app to exit and forwards its stdout/stderr until then.
        ["devicectl", "device", "process", "launch"]
            + (attachConsole ? ["--console"] : [])
            + (includeUnifiedLogs
                ? ["--environment-variables", "{\"OS_ACTIVITY_DT_MODE\":\"YES\"}"]
                : [])
            + ["--device", artifact.destination.udid, artifact.bundleIdentifier]
    }

    static func physicalDeviceInstallLaunchArguments(for artifact: BuildArtifact) -> [[String]] {
        [
            physicalDeviceInstallArguments(for: artifact),
            physicalDeviceLaunchArguments(for: artifact)
        ]
    }

    static func physicalDeviceAppIconArguments(
        for artifact: BuildArtifact,
        destinationURL: URL
    ) -> [String] {
        [
            "devicectl", "--timeout", "30", "device", "info", "appIcon",
            "--device", artifact.destination.udid,
            "--app-bundle-id", artifact.bundleIdentifier,
            "--destination", destinationURL.path
        ]
    }

    static func localAppMetadata(for appURL: URL) throws -> AppBundleMetadata {
        let bundleIdentifier = try bundleIdentifier(for: appURL)
        let infoURL = infoPlistURL(for: appURL)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            throw AppFailure(message: "The built app at \(appURL.path) has no readable Info.plist.")
        }

        let displayName = firstString(
            in: [plist],
            keys: ["CFBundleDisplayName", "CFBundleName"]
        ) ?? appURL.deletingPathExtension().lastPathComponent
        let icon = localAppIcon(from: plist, appURL: appURL)
        return AppBundleMetadata(
            appURL: appURL,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            icon: icon
        )
    }

    static func localAppIcon(from plist: [String: Any], appURL: URL) -> AppIcon? {
        let candidateNames = iconFileNames(from: plist)
        let resourceRoots = [
            appURL,
            appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        ]
        for candidateName in candidateNames {
            for resourceRoot in resourceRoots {
                let candidateURL = resourceRoot.appendingPathComponent(candidateName)
                if let data = try? Data(contentsOf: candidateURL), !data.isEmpty {
                    return AppIcon(data: data, sourceURL: candidateURL)
                }
            }
        }

        // Some modern bundles only retain an asset catalog. The compiled
        // Assets.car is not a portable image source, but NSWorkspace can still
        // resolve the bundle's installed icon when the app is present locally.
        let workspaceIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        if let tiffData = workspaceIcon.tiffRepresentation, !tiffData.isEmpty {
            return AppIcon(data: tiffData, sourceURL: nil)
        }
        return nil
    }

    static func iconFileNames(from plist: [String: Any]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value, !value.xerTrimmed.isEmpty else { return }
            let name = value.xerTrimmed
            guard seen.insert(name).inserted else { return }
            names.append(name)
            if URL(fileURLWithPath: name).pathExtension.isEmpty {
                let pngName = "\(name).png"
                if seen.insert(pngName).inserted {
                    names.append(pngName)
                }
            }
        }

        add(plist["CFBundleIconFiles"] as? String)
        if let iconFiles = plist["CFBundleIconFiles"] as? [String] {
            iconFiles.forEach(add)
        }
        if let iconFiles = plist["CFBundleIconFiles"] as? [Any] {
            iconFiles.compactMap { $0 as? String }.forEach(add)
        }
        add(plist["CFBundleIconFile"] as? String)

        func addIconFiles(from dictionary: [String: Any]) {
            if let iconFiles = dictionary["CFBundleIconFiles"] as? [String] {
                iconFiles.forEach(add)
            }
            if let iconFiles = dictionary["CFBundleIconFiles"] as? [Any] {
                iconFiles.compactMap { $0 as? String }.forEach(add)
            }
            add(dictionary["CFBundleIconFile"] as? String)
        }

        // iPad-specific icon dictionaries are emitted under CFBundleIcons~ipad
        // by some older/universal products, so inspect all platform variants.
        for (key, value) in plist where key == "CFBundleIcons" || key.hasPrefix("CFBundleIcons~") {
            guard let iconDictionary = value as? [String: Any] else { continue }
            for iconKey in ["CFBundlePrimaryIcon", "CFBundleAlternateIcons"] {
                guard let value = iconDictionary[iconKey] else { continue }
                let dictionaries: [[String: Any]]
                if let dictionary = value as? [String: Any] {
                    dictionaries = [dictionary]
                } else if let alternate = value as? [String: [String: Any]] {
                    dictionaries = Array(alternate.values)
                } else {
                    dictionaries = []
                }
                dictionaries.forEach { addIconFiles(from: $0) }
            }
        }

        return names
    }

    static func simulatorBootArguments(for destination: Destination) -> [[String]] {
        [
            ["simctl", "boot", destination.udid],
            ["simctl", "bootstatus", destination.udid, "-b"]
        ]
    }

    static func containerArguments(for project: ImportedProject) -> [String] {
        switch project.kind {
        case .workspace:
            return ["-workspace", project.path]
        case .project:
            return ["-project", project.path]
        }
    }

    // MARK: - Parsers (kept pure for fixture-based tests)

    static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return jsonObject(from: data)
    }

    static func jsonObject(from data: Data) -> Any? {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        // xcodebuild occasionally prefixes diagnostics around machine-readable
        // output. Recover the first complete JSON object without treating any
        // diagnostic text as JSON.
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let candidate = String(text[start...])
        return try? JSONSerialization.jsonObject(with: Data(candidate.utf8))
    }

    static func schemeNames(in object: Any) -> [String] {
        var names = Set<String>()

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let schemes = dictionary["schemes"] as? [Any] {
                    for scheme in schemes {
                        if let name = scheme as? String, !name.isEmpty {
                            names.insert(name)
                        }
                    }
                }
                for child in dictionary.values { visit(child) }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }

        visit(object)
        return Array(names)
    }

    static func simulatorDestinations(from object: Any) throws -> [Destination] {
        guard let root = object as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else {
            throw AppFailure(message: "simctl returned an unreadable simulator list.")
        }

        var destinations: [Destination] = []
        for (runtimeIdentifier, value) in devicesByRuntime {
            guard let devices = value as? [[String: Any]] else { continue }
            for device in devices {
                let isAvailable = Self.boolValue(device["isAvailable"]) ?? true
                guard isAvailable,
                      let udid = stringValue(device, keys: ["udid"]),
                      let name = stringValue(device, keys: ["name"]) else {
                    continue
                }

                let runtime = Self.runtimeInformation(from: runtimeIdentifier)
                let platform = stringValue(device, keys: ["platform"]) ?? runtime.platform
                let osVersion = stringValue(device, keys: ["osVersion"]) ?? runtime.version
                let state = stringValue(device, keys: ["state"])
                let modelName = stringValue(device, keys: ["deviceTypeIdentifier", "modelIdentifier"])
                destinations.append(Destination(
                    udid: udid,
                    name: name,
                    platform: platform,
                    osVersion: osVersion,
                    state: state,
                    kind: .simulator,
                    isAvailable: true,
                    modelName: modelName
                ))
            }
        }
        return Self.deduplicated(destinations)
    }

    static func physicalDestinations(from object: Any) throws -> [Destination] {
        guard let root = object as? [String: Any],
              let result = dictionaryValue(root["result"]),
              let rawDevices = result["devices"] as? [[String: Any]] else {
            throw AppFailure(message: "devicectl returned an unreadable connected-device list.")
        }

        var destinations: [Destination] = []
        for rawDevice in rawDevices {
            let deviceProperties = dictionaryValue(rawDevice["deviceProperties"]) ?? [:]
            let hardwareProperties = dictionaryValue(rawDevice["hardwareProperties"]) ?? [:]
            let connectionProperties = dictionaryValue(rawDevice["connectionProperties"]) ?? [:]

            // devicectl also reports CoreSimulator devices. Simulators come from
            // simctl, so do not duplicate them in the physical-device section.
            let reality = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["reality", "deviceReality"]
            )?.lowercased()
            let provider = firstString(
                in: [deviceProperties, hardwareProperties, rawDevice],
                keys: ["provider"]
            )?.lowercased()
            let visibilityClass = stringValue(rawDevice, keys: ["visibilityClass"])?.lowercased()
            if reality == "simulated"
                || provider?.contains("simulator") == true
                || visibilityClass == "simulators" {
                continue
            }

            // xcodebuild destinations use the hardware UDID. devicectl exposes a
            // CoreDevice UUID at the top level, so prefer hardwareProperties.udid.
            let udid = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["udid", "deviceIdentifier", "identifier"]
            )
            guard let udid, !udid.isEmpty else { continue }

            let connectionState = firstString(
                in: [connectionProperties, rawDevice, deviceProperties],
                keys: ["connectionState", "connectionStatus", "state", "status", "tunnelState"]
            )
            let pairingState = firstString(
                in: [connectionProperties, rawDevice, deviceProperties],
                keys: ["pairingState", "pairingStatus"]
            )
            let developerMode = firstString(
                in: [deviceProperties, rawDevice],
                keys: ["developerModeStatus", "developerMode"]
            )
            let isAvailable = isUsableDevice(
                connectionState: connectionState,
                pairingState: pairingState,
                developerMode: developerMode
            )

            let name = firstString(
                in: [deviceProperties, rawDevice, hardwareProperties],
                keys: ["name", "deviceName", "displayName", "marketingName"]
            ) ?? "Device \(udid.prefix(8))"
            let platform = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["platform", "platformName", "productType"]
            ) ?? "Apple device"
            let osVersion = firstString(
                in: [deviceProperties, rawDevice, hardwareProperties],
                keys: ["osVersion", "osVersionNumber", "operatingSystemVersion", "version"]
            )
            let state = connectionState
                ?? pairingState
                ?? developerMode
                ?? "connected"
            let modelName = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["marketingName", "modelName", "productType", "hardwareModel"]
            )
            let batteryLevel = firstNumber(
                in: [deviceProperties, hardwareProperties, rawDevice],
                keys: ["batteryLevel", "batteryPercentage", "batteryCurrentCapacity"]
            ).map { value in
                let percentage = value <= 1 ? value * 100 : value
                return min(max(Int(percentage.rounded()), 0), 100)
            }

            destinations.append(Destination(
                udid: udid,
                name: name,
                platform: platform,
                osVersion: osVersion,
                state: state,
                kind: .physicalDevice,
                isAvailable: isAvailable,
                modelName: modelName,
                batteryLevel: batteryLevel
            ))
        }

        return deduplicated(destinations)
    }

    static func bundleIdentifier(for appURL: URL) throws -> String {
        let infoURL = infoPlistURL(for: appURL)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.xerTrimmed.isEmpty else {
            throw AppFailure(message: "The built app at \(appURL.path) has no CFBundleIdentifier.")
        }
        return identifier
    }

    private static func infoPlistURL(for appURL: URL) -> URL {
        let macOSInfoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: macOSInfoURL.path) {
            return macOSInfoURL
        }
        return appURL.appendingPathComponent("Info.plist")
    }

    private static func localMacExecutableURL(for appURL: URL) throws -> URL {
        let infoURL = infoPlistURL(for: appURL)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let executableName = plist["CFBundleExecutable"] as? String,
              !executableName.xerTrimmed.isEmpty else {
            throw AppFailure(message: "The built Mac app has no CFBundleExecutable and cannot be launched.")
        }
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppFailure(message: "The built Mac app executable was not found at \(executableURL.path).")
        }
        return executableURL
    }

    // MARK: - Process execution

    private func validate(_ artifact: BuildArtifact) throws {
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

    private func bootSimulatorIfNeeded(
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

    private func invoke(
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

    private func check(_ result: ProcessResult, arguments: [String]) throws {
        try check(result, executableURL: xcrunURL, arguments: arguments)
    }

    private func check(
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

    private func findBuiltApplication(in derivedDataURL: URL, preferredName: String) throws -> URL {
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

    private static func isUsableDevice(
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

    private static func runtimeInformation(from identifier: String) -> RuntimeInformation {
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

    private static func deduplicated(_ destinations: [Destination]) -> [Destination] {
        var seen = Set<String>()
        return Destination.sorted(
            destinations.filter { seen.insert($0.id).inserted }
        )
    }
}

private struct RuntimeInformation {
    let platform: String
    let version: String?
}

private func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func firstString(in dictionaries: [[String: Any]], keys: [String]) -> String? {
    for dictionary in dictionaries {
        if let value = stringValue(dictionary, keys: keys) {
            return value
        }
    }
    return nil
}

private func firstNumber(in dictionaries: [[String: Any]], keys: [String]) -> Double? {
    for dictionary in dictionaries {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.doubleValue
            }
            if let text = dictionary[key] as? String, let number = Double(text) {
                return number
            }
        }
    }
    return nil
}

private func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = dictionary[key] as? String, !value.xerTrimmed.isEmpty {
            return value
        }
    }
    return nil
}

private extension DeveloperTooling {
    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "available": return true
            case "false", "no", "unavailable": return false
            default: return nil
            }
        }
        return nil
    }
}
