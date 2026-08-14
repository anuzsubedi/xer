import Foundation

/// The project container types that xcodebuild can open without launching Xcode.
enum ProjectKind: String, Codable, CaseIterable, Sendable {
    case workspace
    case project

    var fileExtension: String {
        switch self {
        case .workspace:
            return "xcworkspace"
        case .project:
            return "xcodeproj"
        }
    }

    var displayName: String {
        switch self {
        case .workspace:
            return "Workspace"
        case .project:
            return "Project"
        }
    }
}

struct SharedScheme: Identifiable, Codable, Hashable, Sendable {
    let name: String

    var id: String { name }
}

struct ImportedProject: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let kind: ProjectKind
    var schemes: [SharedScheme]
    var isTrusted: Bool
    var parentPath: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

enum DestinationKind: String, Codable, Sendable {
    case localMac
    case simulator
    case physicalDevice

    var displayName: String {
        switch self {
        case .localMac:
            return "Mac"
        case .simulator:
            return "Simulator"
        case .physicalDevice:
            return "Physical device"
        }
    }
}

struct Destination: Identifiable, Codable, Hashable, Sendable {
    let udid: String
    let name: String
    let platform: String
    let osVersion: String?
    let state: String?
    let kind: DestinationKind
    let isAvailable: Bool
    var modelName: String? = nil
    var batteryLevel: Int? = nil

    /// Prefixing the identifier avoids a collision if a simulator and a physical
    /// device ever expose the same identifier-shaped value.
    var id: String { "\(kind.rawValue):\(udid)" }
    var xcodebuildSpecifier: String {
        switch kind {
        case .localMac:
            return "platform=macOS,arch=\(Self.hostArchitecture)"
        case .simulator, .physicalDevice:
            return "id=\(udid)"
        }
    }

    static var localMac: Destination {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Destination(
            udid: "local-mac-\(hostArchitecture)",
            name: "This Mac",
            platform: "macOS",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            state: "Ready",
            kind: .localMac,
            isAvailable: true,
            modelName: ProcessInfo.processInfo.hostName
        )
    }

    /// Whether a physical destination reports an affirmative connection state.
    /// `isAvailable` also includes pairing and Developer Mode checks, so it is
    /// intentionally kept separate from this value for sorting and searching.
    var isConnected: Bool {
        guard kind == .physicalDevice, isAvailable else { return false }
        let value = Self.normalizedSearchText(state ?? "")
        if value.isEmpty {
            // An available physical destination with no explicit state is still
            // a connected CoreDevice; unavailable devices are handled above.
            return true
        }
        let disconnectedTerms = [
            "disconnected", "not connected", "notconnected", "offline", "unavailable", "unpaired",
            "pairing required", "pairingrequired", "disabled", "not enabled", "notenabled",
            "developermodedisabled", "developermodenotenabled", "unknown"
        ]
        if disconnectedTerms.contains(where: value.contains) {
            return false
        }
        // Any state not explicitly known to be disconnected is considered
        // connected once CoreDevice has marked the destination available.
        return true
    }

    /// Whether this destination can be selected for build/deploy operations.
    /// Physical devices must be both available to CoreDevice and connected;
    /// otherwise they remain visible as unavailable diagnostics only.
    var isReadyForDevelopment: Bool {
        isAvailable && (kind != .physicalDevice || isConnected)
    }

    /// Lower values are shown first. This Mac comes first, followed by connected
    /// physical devices, simulators, and unavailable destinations.
    /// This is a model-level ordering so callers do not have to duplicate the
    /// readiness rules in each presentation.
    var connectionSortRank: Int {
        switch kind {
        case .localMac:
            return 0
        case .physicalDevice:
            return isConnected ? 1 : 3
        case .simulator:
            return isAvailable ? 2 : 3
        }
    }

    /// Fields used by the model's destination search. Include both the raw
    /// values and useful status aliases so searches such as "offline" and
    /// "ready" work even when the tool reports a different status spelling.
    var searchableText: String {
        var values = [
            name,
            udid,
            platform,
            kind.rawValue,
            kind.displayName
        ]
        values.append(contentsOf: [osVersion, state].compactMap { $0 })
        if isReadyForDevelopment {
            values.append("available ready")
            if kind == .physicalDevice {
                values.append("connected online paired")
            }
        } else {
            values.append("unavailable disconnected offline")
        }
        return values.joined(separator: " ")
    }

    func matchesSearch(_ query: String) -> Bool {
        let terms = Self.normalizedSearchText(query)
            .split(separator: " ")
            .map(String.init)
        guard !terms.isEmpty else { return true }

        let haystack = Self.normalizedSearchText(searchableText)
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Provides one canonical ordering for destination lists. Ties sort
    /// naturally by name and identifier.
    static func sorted(_ destinations: [Destination]) -> [Destination] {
        destinations.sorted { lhs, rhs in
            if lhs.connectionSortRank != rhs.connectionSortRank {
                return lhs.connectionSortRank < rhs.connectionSortRank
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.udid < rhs.udid
        }
    }

    var subtitle: String {
        var pieces = [platform]
        if let osVersion, !osVersion.isEmpty {
            pieces.append(osVersion)
        }
        if let state, !state.isEmpty {
            pieces.append(state)
        }
        return pieces.joined(separator: " • ")
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static var hostArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "undefined_arch"
#endif
    }
}

/// A small, transportable representation of an app icon. Keeping image bytes
/// rather than an `NSImage` lets the tooling layer discover icons off the main
/// actor and gives SwiftUI a stable value to render later.
struct AppIcon: Hashable, Sendable {
    let data: Data
    let sourceURL: URL?

    init(data: Data, sourceURL: URL? = nil) {
        self.data = data
        self.sourceURL = sourceURL
    }

    var isUsable: Bool {
        !data.isEmpty || sourceURL != nil
    }
}

struct AppBundleMetadata: Hashable, Sendable {
    let appURL: URL
    let bundleIdentifier: String
    let displayName: String
    let icon: AppIcon?
}

enum ProcessStream: String, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { terminationStatus == 0 }
    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct ProcessOutput: Sendable {
    let stream: ProcessStream
    let text: String
}

enum AppOperationState: Equatable, Sendable {
    case idle
    case importing
    case refreshingDestinations
    case refreshingSchemes
    case preparingBuild
    case building(completed: Int, total: Int)
    case installing(completed: Int, total: Int)
    case launching
    case running
    case cancelling
    case succeeded
    case failed(String)
    case cancelled

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .importing:
            return "Importing projects…"
        case .refreshingDestinations:
            return "Refreshing destinations…"
        case .refreshingSchemes:
            return "Refreshing schemes…"
        case .preparingBuild:
            return "Constructing build description…"
        case let .building(completed, total):
            return "Building \(completed)/\(total)…"
        case let .installing(completed, total):
            return "Installing \(completed)/\(total)…"
        case .launching:
            return "Launching…"
        case .running:
            return "Running"
        case .cancelling:
            return "Cancelling…"
        case .succeeded:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    enum Level: Sendable {
        case info
        case warning
        case error
        case command
    }

    let id = UUID()
    let date = Date()
    let level: Level
    let message: String
}

struct BuildArtifact: Sendable {
    let appURL: URL
    let bundleIdentifier: String
    let destination: Destination
    let displayName: String?
    let appIcon: AppIcon?

    init(
        appURL: URL,
        bundleIdentifier: String,
        destination: Destination,
        displayName: String? = nil,
        appIcon: AppIcon? = nil
    ) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
        self.destination = destination
        self.displayName = displayName
        self.appIcon = appIcon
    }
}

/// Metadata made available as soon as an app has been installed. The icon is
/// optional because some build products do not declare an icon or a device may
/// not support icon retrieval.
struct InstalledApp: Identifiable, Hashable, Sendable {
    let appURL: URL
    let bundleIdentifier: String
    let displayName: String
    let icon: AppIcon?
    let destination: Destination

    var id: String { "\(destination.id):\(bundleIdentifier)" }

    init(artifact: BuildArtifact, icon: AppIcon? = nil) {
        self.appURL = artifact.appURL
        self.bundleIdentifier = artifact.bundleIdentifier
        self.displayName = artifact.displayName
            ?? artifact.appURL.deletingPathExtension().lastPathComponent
        self.icon = icon ?? artifact.appIcon
        self.destination = artifact.destination
    }
}

struct StoredProject: Codable, Sendable {
    let path: String
    let kind: ProjectKind
    var schemes: [SharedScheme]
    var isTrusted: Bool
    var parentPath: String?
    var bookmarkData: Data?
}

struct DiscoveryResult: Sendable {
    let projects: [ImportedProject]
    let parentURL: URL
}

struct ToolFailure: Error, LocalizedError, @unchecked Sendable {
    let command: String
    let status: Int32?
    let output: String
    let underlyingMessage: String?

    var errorDescription: String? {
        if let underlyingMessage {
            return "\(command): \(underlyingMessage)"
        }
        if output.isEmpty {
            return "\(command) failed (exit \(status.map(String.init) ?? "unknown"))."
        }
        return "\(command) failed (exit \(status.map(String.init) ?? "unknown")): \(output)"
    }
}

struct AppFailure: Error, LocalizedError, @unchecked Sendable {
    let message: String

    var errorDescription: String? { message }
}

extension String {
    var xerTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
