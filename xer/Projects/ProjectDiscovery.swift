import AppKit
import Foundation

struct DiscoveredProject: Sendable, Hashable {
    let url: URL
    let kind: ProjectKind
}

struct ProjectDiscovery: Sendable {
    func discover(in parentURL: URL) -> [DiscoveredProject] {
        let fileManager = FileManager.default
        let normalizedParent = parentURL.standardizedFileURL

        if let parentKind = kind(of: normalizedParent) {
            return [DiscoveredProject(url: normalizedParent, kind: parentKind)]
        }

        guard (try? normalizedParent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let enumerator = fileManager.enumerator(
                  at: normalizedParent,
                  includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var found: [DiscoveredProject] = []
        var seenPaths = Set<String>()
        for case let url as URL in enumerator {
            guard let projectKind = kind(of: url) else { continue }
            let normalizedURL = url.standardizedFileURL
            guard seenPaths.insert(normalizedURL.path).inserted else { continue }
            found.append(DiscoveredProject(url: normalizedURL, kind: projectKind))
        }

        return found.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    func kind(of url: URL) -> ProjectKind? {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        switch url.pathExtension.lowercased() {
        case ProjectKind.workspace.fileExtension:
            return .workspace
        case ProjectKind.project.fileExtension:
            return .project
        default:
            return nil
        }
    }

    /// Reads shared scheme filenames only. Importing an untrusted project must
    /// not invoke xcodebuild or execute package plugins/build phases.
    func sharedSchemes(in projectURL: URL) -> [SharedScheme] {
        let schemesURL = projectURL
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: schemesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var names = Set<String>()
        for file in files where file.pathExtension.caseInsensitiveCompare("xcscheme") == .orderedSame {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let name = file.deletingPathExtension().lastPathComponent
            if !name.isEmpty { names.insert(name) }
        }

        return names
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(SharedScheme.init(name:))
    }

}
