import AppKit
import SwiftUI

enum SidebarRemovalCandidate: Identifiable {
    case project(ImportedProject)
    case folder(path: String, name: String, projectCount: Int)

    var id: String {
        switch self {
        case .project(let project): "project:\(project.id)"
        case .folder(let path, _, _): "folder:\(path)"
        }
    }

    var title: String {
        switch self {
        case .project: "Remove Project?"
        case .folder: "Remove Imported Folder?"
        }
    }

    var message: String {
        switch self {
        case .project(let project):
            "This removes \(project.displayName) from xer. Files on disk are not deleted."
        case .folder(_, let name, let projectCount):
            "This removes \(name) and its \(projectCount) project record(s) from xer. Files on disk are not deleted."
        }
    }
}

struct SidebarProjectGroup: Identifiable {
    let folderPath: String
    let projects: [ImportedProject]
    let totalProjectCount: Int

    var id: String { folderPath }
    var displayName: String {
        URL(fileURLWithPath: folderPath, isDirectory: true).lastPathComponent
    }
}

struct InstalledAppSummary: View {
    let apps: [InstalledApp]

    private var firstApp: InstalledApp { apps[0] }
    private var representativeApp: InstalledApp {
        apps.first(where: { $0.icon?.isUsable == true }) ?? firstApp
    }

    var body: some View {
        HStack(spacing: 7) {
            InstalledAppIcon(icon: representativeApp.icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(firstApp.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(apps.count == 1 ? firstApp.destination.name : "\(apps.count) destinations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 2)
        .help(apps.map { "\($0.displayName) — \($0.destination.name)" }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(apps.count == 1
            ? "Installed app \(firstApp.displayName) on \(firstApp.destination.name)"
            : "Installed app \(firstApp.displayName) on \(apps.count) destinations")
    }
}

struct InstalledAppIcon: View {
    let icon: AppIcon?

    var body: some View {
        AppIconArtwork(
            icon: icon,
            fallbackSystemName: "app.fill",
            fallbackColor: Color.accentColor
        )
    }
}

struct ProjectRow: View {
    let project: ImportedProject
    let icon: AppIcon?

    var body: some View {
        HStack(spacing: 9) {
            AppIconArtwork(
                icon: icon,
                fallbackSystemName: project.kind == .workspace ? "square.stack.3d.up" : "hammer",
                fallbackColor: project.isTrusted ? Color.accentColor : Color.orange,
                size: 34
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(compactPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityValue(project.isTrusted ? "Trusted" : "Trust required")
    }

    private var compactPath: String {
        (project.path as NSString).abbreviatingWithTildeInPath
    }
}

struct AppIconArtwork: View {
    let icon: AppIcon?
    let fallbackSystemName: String
    let fallbackColor: Color
    var size: CGFloat = 28

    var body: some View {
        let image = resolvedImage
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(fallbackColor.opacity(0.13))
                    Image(systemName: fallbackSystemName)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(fallbackColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            if image != nil {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
        .shadow(
            color: image == nil ? .clear : Color.black.opacity(0.22),
            radius: 1.5,
            x: 0,
            y: 1
        )
        .accessibilityHidden(true)
    }

    private var resolvedImage: NSImage? {
        if let icon, !icon.data.isEmpty, let image = NSImage(data: icon.data) {
            return image
        }
        if let url = icon?.sourceURL {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
