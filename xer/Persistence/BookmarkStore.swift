import AppKit
import Foundation

/// The app is deliberately not sandboxed so it can invoke Xcode's developer
/// tools and build imported projects. Keep this check for bookmark/scoped-access
/// compatibility when the target is embedded in a separately sandboxed build.
enum AppSandbox {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

/// Keeps a security-scoped URL alive for as long as an imported project is in
/// use. This is a no-op for the normal unsandboxed xer target, but makes the
/// persistence layer safe if the target is ever run in a sandboxed host.
final class SecurityScopeAccess: @unchecked Sendable {
    let url: URL
    let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = AppSandbox.isEnabled && url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// Persists paths for every build and security-scoped bookmarks when sandboxed.
/// A path fallback is intentional: xer is a developer utility with App Sandbox
/// disabled, and path persistence should still work after a restart. Bookmarks
/// are only requested in a sandboxed process, where they are meaningful.
final class BookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let parentBookmarkKey = "xer.parentFolderBookmark"
    private let parentPathKey = "xer.parentFolderPath"
    private let projectsKey = "xer.importedProjects"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func saveParentFolder(_ url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        defaults.set(normalizedURL.path, forKey: parentPathKey)

        guard AppSandbox.isEnabled else {
            defaults.removeObject(forKey: parentBookmarkKey)
            return true
        }

        guard let data = makeBookmark(for: normalizedURL) else {
            return false
        }
        defaults.set(data, forKey: parentBookmarkKey)
        return true
    }

    func resolveParentFolder() -> URL? {
        if let data = defaults.data(forKey: parentBookmarkKey),
           let resolved = resolveBookmark(data),
           isDirectory(resolved) {
            return resolved.standardizedFileURL
        }

        guard let path = defaults.string(forKey: parentPathKey) else { return nil }
        let fallback = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return isDirectory(fallback) ? fallback : nil
    }

    func removeParentFolder(matching path: String) {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard let storedPath = defaults.string(forKey: parentPathKey),
              URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL.path == normalizedPath else {
            return
        }
        defaults.removeObject(forKey: parentPathKey)
        defaults.removeObject(forKey: parentBookmarkKey)
    }

    @discardableResult
    func saveProject(_ project: ImportedProject) -> Bool {
        var records = loadStoredProjects()
        let normalizedPath = project.url.standardizedFileURL.path
        let oldRecord = records.first { $0.path == normalizedPath || $0.path == project.path }
        let bookmarkData = makeBookmark(for: project.url)
            ?? oldRecord?.bookmarkData

        let record = StoredProject(
            path: normalizedPath,
            kind: project.kind,
            schemes: project.schemes,
            isTrusted: project.isTrusted,
            parentPath: project.parentPath,
            bookmarkData: bookmarkData
        )
        records.removeAll { $0.path == project.path || $0.path == normalizedPath }
        records.append(record)
        let didSave = saveStoredProjects(records)
        return didSave && (!AppSandbox.isEnabled || bookmarkData != nil)
    }

    func removeProjects(notIn paths: Set<String>) {
        let normalizedPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let records = loadStoredProjects().filter { normalizedPaths.contains($0.path) }
        _ = saveStoredProjects(records)
    }

    func storedProjects() -> [StoredProject] {
        loadStoredProjects()
    }

    func resolveProject(_ record: StoredProject) -> URL? {
        if let bookmarkData = record.bookmarkData,
           let resolved = resolveBookmark(bookmarkData),
           isDirectory(resolved) {
            return resolved.standardizedFileURL
        }

        let fallback = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
        return isDirectory(fallback) ? fallback : nil
    }

    private func makeBookmark(for url: URL) -> Data? {
        guard AppSandbox.isEnabled else { return nil }
        return try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        // A stale bookmark can still resolve to the right URL. The path fallback
        // remains available, and a subsequent save can replace the bookmark.
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func loadStoredProjects() -> [StoredProject] {
        guard let data = defaults.data(forKey: projectsKey),
              let records = try? JSONDecoder().decode([StoredProject].self, from: data) else {
            return []
        }

        var unique: [String: StoredProject] = [:]
        for record in records {
            let normalizedPath = URL(fileURLWithPath: record.path, isDirectory: true)
                .standardizedFileURL.path
            unique[normalizedPath] = StoredProject(
                path: normalizedPath,
                kind: record.kind,
                schemes: record.schemes,
                isTrusted: record.isTrusted,
                parentPath: record.parentPath,
                bookmarkData: record.bookmarkData
            )
        }
        return unique.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    @discardableResult
    private func saveStoredProjects(_ records: [StoredProject]) -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: projectsKey)
        return true
    }
}
