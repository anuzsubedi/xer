import AppKit
import Foundation

extension DeveloperTooling {
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
}
