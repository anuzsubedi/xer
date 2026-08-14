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

    /// Finds the best source image in an app icon asset set near an imported
    /// project. This only reads asset-catalog metadata and image bytes; it does
    /// not invoke xcodebuild or otherwise execute untrusted project code.
    func appIcon(in projectURL: URL) -> AppIcon? {
        let searchRoot = projectURL.deletingLastPathComponent().standardizedFileURL
        let preferredNames = configuredAppIconNames(near: projectURL)
        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(priority: Int, url: URL)] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let pathExtension = url.pathExtension.lowercased()
            if pathExtension == ProjectKind.project.fileExtension
                || pathExtension == ProjectKind.workspace.fileExtension
                || ["git", "build", "deriveddata", "pods"].contains(url.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }

            let isAssetCatalogIcon = pathExtension == "appiconset"
            let isIconComposerIcon = pathExtension == "icon"
                && FileManager.default.fileExists(atPath: url.appendingPathComponent("icon.json").path)
            guard isAssetCatalogIcon || isIconComposerIcon else { continue }
            enumerator.skipDescendants()
            let name = url.deletingPathExtension().lastPathComponent
            let preferredIndex = preferredNames.firstIndex(of: name)
            let configuredPriority = preferredIndex.map { 10_000 - $0 } ?? (name == "AppIcon" ? 5_000 : 0)
            // Icon Composer is the source of truth when a project also retains
            // an empty AppIcon.appiconset as a build-settings placeholder.
            let priority = configuredPriority + (isIconComposerIcon ? 250 : 0)
            candidates.append((priority, url))
        }

        for candidate in candidates.sorted(by: {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }) {
            let icon = candidate.url.pathExtension.lowercased() == "icon"
                ? appIcon(fromIconComposer: candidate.url)
                : appIcon(from: candidate.url)
            if let icon {
                return icon
            }
        }
        return nil
    }

    private func configuredAppIconNames(near projectURL: URL) -> [String] {
        let projectFiles: [URL]
        if projectURL.pathExtension.lowercased() == ProjectKind.project.fileExtension {
            projectFiles = [projectURL.appendingPathComponent("project.pbxproj")]
        } else {
            let root = projectURL.deletingLastPathComponent()
            projectFiles = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?
                .filter { $0.pathExtension.lowercased() == ProjectKind.project.fileExtension }
                .map { $0.appendingPathComponent("project.pbxproj") } ?? []
        }

        var names: [String] = []
        for file in projectFiles {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: \.isNewline) {
                guard line.contains("ASSETCATALOG_COMPILER_APPICON_NAME"),
                      let equalsIndex = line.firstIndex(of: "=") else { continue }
                let rawName = line[line.index(after: equalsIndex)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t;\""))
                if !rawName.isEmpty, !names.contains(rawName) {
                    names.append(rawName)
                }
            }
        }
        return names
    }

    private func appIcon(from appIconSetURL: URL) -> AppIcon? {
        let contentsURL = appIconSetURL.appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: contentsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["images"] as? [[String: Any]] else {
            return nil
        }

        let rankedFiles = images.compactMap { image -> (score: Double, url: URL)? in
            guard let filename = image["filename"] as? String, !filename.isEmpty else { return nil }
            let dimensions = (image["size"] as? String)?
                .split(separator: "x")
                .compactMap { Double($0) } ?? []
            let scaleText = (image["scale"] as? String)?.replacingOccurrences(of: "x", with: "")
            let scale = Double(scaleText ?? "") ?? 1
            let area = dimensions.count == 2 ? dimensions[0] * dimensions[1] * scale * scale : 0
            let idiomBonus = (image["idiom"] as? String) == "ios-marketing" ? 1_000_000_000 : 0
            return (area + Double(idiomBonus), appIconSetURL.appendingPathComponent(filename))
        }
        .sorted { $0.score > $1.score }

        for candidate in rankedFiles {
            if let data = try? Data(contentsOf: candidate.url), !data.isEmpty {
                return AppIcon(data: data, sourceURL: candidate.url)
            }
        }
        return nil
    }

    /// Icon Composer stores layered source artwork in a sibling `Assets`
    /// directory. Composite the visible default-appearance layers over the
    /// declared icon fill so the sidebar shows the complete app icon rather
    /// than one isolated source layer.
    private func appIcon(fromIconComposer iconURL: URL) -> AppIcon? {
        let metadataURL = iconURL.appendingPathComponent("icon.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]] else {
            return nil
        }

        let assetsURL = iconURL.appendingPathComponent("Assets", isDirectory: true)
        let canvasSize = NSSize(width: 1024, height: 1024)
        let canvasRect = NSRect(origin: .zero, size: canvasSize)
        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()

        drawIconFill(object["fill"], in: canvasRect)

        var renderedLayer = false
        for group in groups.reversed() {
            guard let layers = group["layers"] as? [[String: Any]] else { continue }
            for layer in layers.reversed() {
                guard layer["hidden"] as? Bool != true,
                      isVisibleInDefaultAppearance(layer),
                      let imageName = layer["image-name"] as? String,
                      !imageName.isEmpty else { continue }
                let imageURL = assetsURL.appendingPathComponent(imageName)
                guard let image = NSImage(contentsOf: imageURL) else { continue }
                let opacity = (layer["opacity"] as? NSNumber)?.doubleValue ?? 1
                let renderedImage = imageApplyingFill(to: image, fill: layer["fill"], size: canvasSize)
                renderedImage.draw(
                    in: canvasRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: min(max(opacity, 0), 1),
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                renderedLayer = true
            }
        }
        canvas.unlockFocus()

        guard renderedLayer,
              let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return AppIcon(data: png)
    }

    private func imageApplyingFill(to image: NSImage, fill: Any?, size: NSSize) -> NSImage {
        guard let dictionary = fill as? [String: Any],
              let encodedColor = dictionary["solid"] as? String,
              let color = iconColor(from: encodedColor) else {
            return image
        }

        let result = NSImage(size: size)
        let rect = NSRect(origin: .zero, size: size)
        result.lockFocus()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .sourceIn
        color.setFill()
        NSBezierPath(rect: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        result.unlockFocus()
        return result
    }

    private func iconFillColor(from value: Any?) -> NSColor? {
        if let dictionary = value as? [String: Any] {
            if let solid = dictionary["solid"] as? String {
                return iconColor(from: solid)
            }
            if let gradient = dictionary["automatic-gradient"] as? String {
                return iconColor(from: gradient)
            }
        }
        if let value = value as? String, value == "automatic" {
            return NSColor(calibratedWhite: 0.12, alpha: 1)
        }
        return NSColor.clear
    }

    private func drawIconFill(_ value: Any?, in rect: NSRect) {
        if let dictionary = value as? [String: Any],
           let encodedGradient = dictionary["automatic-gradient"] as? String,
           let base = iconColor(from: encodedGradient) {
            let top = base.blended(withFraction: 0.16, of: .white) ?? base
            let bottom = base.blended(withFraction: 0.18, of: .black) ?? base
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
            return
        }
        (iconFillColor(from: value) ?? .clear).setFill()
        NSBezierPath(rect: rect).fill()
    }

    private func iconColor(from encoded: String) -> NSColor? {
        guard let separator = encoded.firstIndex(of: ":") else { return nil }
        let components = encoded[encoded.index(after: separator)...]
            .split(separator: ",")
            .compactMap { Double($0) }

        if encoded.hasPrefix("extended-gray:"), components.count >= 2 {
            return NSColor(calibratedWhite: components[0], alpha: components[1])
        }
        guard components.count >= 4 else { return nil }
        return NSColor(
            calibratedRed: components[0],
            green: components[1],
            blue: components[2],
            alpha: components[3]
        )
    }

    private func isVisibleInDefaultAppearance(_ layer: [String: Any]) -> Bool {
        if let opacity = layer["opacity"] as? NSNumber, opacity.doubleValue <= 0 {
            return false
        }
        guard let specializations = layer["opacity-specializations"] as? [[String: Any]] else {
            return true
        }
        let defaultOpacity = specializations.first { $0["appearance"] == nil }?["value"] as? NSNumber
        return defaultOpacity?.doubleValue != 0
    }
}
