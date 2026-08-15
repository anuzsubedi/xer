import AppKit
import Foundation

extension ProjectDiscovery {

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

    func configuredAppIconNames(near projectURL: URL) -> [String] {
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

    func appIcon(from appIconSetURL: URL) -> AppIcon? {
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
    func appIcon(fromIconComposer iconURL: URL) -> AppIcon? {
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

    func imageApplyingFill(to image: NSImage, fill: Any?, size: NSSize) -> NSImage {
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

    func iconFillColor(from value: Any?) -> NSColor? {
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

    func drawIconFill(_ value: Any?, in rect: NSRect) {
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

    func iconColor(from encoded: String) -> NSColor? {
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

    func isVisibleInDefaultAppearance(_ layer: [String: Any]) -> Bool {
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
