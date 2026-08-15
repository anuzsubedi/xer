import Foundation

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
