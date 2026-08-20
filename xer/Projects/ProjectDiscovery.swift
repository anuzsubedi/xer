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

    /// Returns the nearest directory xer can import: an Xcode container or a folder
    /// that contains one. Walks upward from `url` when needed.
    func resolveImportRoot(for url: URL) -> URL? {
        var current = url.standardizedFileURL
        if (try? current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            current = current.deletingLastPathComponent()
        }

        while true {
            if kind(of: current) != nil {
                return current
            }
            if !discover(in: current).isEmpty {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    /// Finds an imported project whose container or parent folder contains `url`.
    func matchingProject(in projects: [ImportedProject], for url: URL) -> ImportedProject? {
        let normalizedPath = url.standardizedFileURL.path
        if let exact = projects.first(where: { $0.path == normalizedPath }) {
            return exact
        }

        var current = URL(fileURLWithPath: normalizedPath, isDirectory: true).standardizedFileURL
        while true {
            if let match = projects.first(where: { project in
                project.path == current.path
                    || project.parentPath.map {
                        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
                    } == current.path
            }) {
                return match
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return projects.first { project in
            normalizedPath == project.path
                || normalizedPath.hasPrefix(project.path + "/")
                || project.parentPath.map {
                    normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/")
                } == true
        }
    }

    func preferredProject(in projects: [ImportedProject], for url: URL) -> ImportedProject? {
        if let match = matchingProject(in: projects, for: url) {
            return match
        }
        return nil
    }

    /// Reads scheme filenames from disk only. Importing an untrusted project must
    /// not invoke xcodebuild or execute package plugins/build phases.
    func sharedSchemes(in projectURL: URL) -> [SharedScheme] {
        var names = schemeNames(in: projectURL
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true))

        let userdataURL = projectURL.appendingPathComponent("xcuserdata", isDirectory: true)
        if let userDirectories = try? FileManager.default.contentsOfDirectory(
            at: userdataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in userDirectories
            where directory.pathExtension.caseInsensitiveCompare("xcuserdatad") == .orderedSame {
                names.formUnion(
                    schemeNames(in: directory.appendingPathComponent("xcschemes", isDirectory: true))
                )
            }
        }

        return names
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(SharedScheme.init(name:))
    }

    private func schemeNames(in schemesURL: URL) -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: schemesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var names = Set<String>()
        for file in files where file.pathExtension.caseInsensitiveCompare("xcscheme") == .orderedSame {
            if let isRegularFile = try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
               isRegularFile == false {
                continue
            }
            let name = file.deletingPathExtension().lastPathComponent
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

}
