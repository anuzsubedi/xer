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
