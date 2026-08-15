import AppKit
import SwiftUI

struct DestinationSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Filter destinations", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onKeyPress(.escape) {
                    text = ""
                    return .handled
                }
                .accessibilityLabel("Search destinations")
                .accessibilityHint("Search by device name, simulator, operating system, status, or identifier")

            if text.isEmpty {
                Text("⌥⌘F")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination search")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isFocused.wrappedValue ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

struct DestinationRow: View {
    let destination: Destination
    let isSelected: Bool
    let isFavorite: Bool
    let setSelected: (Bool) -> Void
    let setFavorite: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                setSelected(!isSelected)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: destinationIcon)
                        .foregroundStyle(Color.secondary)
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(destination.name)
                                .font(.callout.weight(.medium))
                            Circle()
                                .fill(destination.isReadyForDevelopment ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            if !destination.isReadyForDevelopment {
                                Text("Unavailable")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(destination.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    if destination.kind == .physicalDevice,
                       let modelName = destination.modelName,
                       !modelName.localizedCaseInsensitiveContains(destination.name) {
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let batteryLevel = destination.batteryLevel {
                        HStack(spacing: 4) {
                            Text("\(batteryLevel)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: batterySymbol(for: batteryLevel))
                                .foregroundStyle(batteryLevel <= 20 ? Color.orange : Color.green)
                        }
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!destination.isReadyForDevelopment)
            .accessibilityLabel("\(destination.name), \(destination.kind.displayName), \(destination.isReadyForDevelopment ? "ready" : "unavailable")")
            .accessibilityHint(destination.isReadyForDevelopment ? "Select this build destination" : "Reconnect, pair, or enable Developer Mode before selecting")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                setFavorite(!isFavorite)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFavorite ? "Remove \(destination.name) from favorites" : "Add \(destination.name) to favorites")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? XerTheme.action.opacity(0.15)
                : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .help(destination.udid)
    }

    private func batterySymbol(for level: Int) -> String {
        switch level {
        case ...10: "battery.0percent"
        case ...35: "battery.25percent"
        case ...65: "battery.50percent"
        case ...90: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var destinationIcon: String {
        switch destination.kind {
        case .localMac: "desktopcomputer"
        case .simulator: "iphone.gen3"
        case .physicalDevice: "iphone"
        }
    }
}

struct DestinationGridCard: View {
    let destination: Destination
    let isSelected: Bool
    let isFavorite: Bool
    let setSelected: (Bool) -> Void
    let setFavorite: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                setSelected(!isSelected)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: destinationIcon)
                        .font(.system(size: 23))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(destination.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Label(
                            destination.isReadyForDevelopment ? "Ready" : "Unavailable",
                            systemImage: destination.isReadyForDevelopment ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(destination.isReadyForDevelopment ? Color.green : Color.orange)
                    }
                    Spacer(minLength: 4)
                }
                .padding(10)
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .background(
                    isSelected ? XerTheme.action.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? XerTheme.action.opacity(0.45) : Color(nsColor: .separatorColor))
                }
            }
            .buttonStyle(.plain)
            .disabled(!destination.isReadyForDevelopment)
            .accessibilityLabel("\(destination.name), \(destination.kind.displayName), \(destination.isReadyForDevelopment ? "ready" : "unavailable")")
            .accessibilityHint(destination.isReadyForDevelopment ? "Select this build destination" : "Reconnect, pair, or enable Developer Mode before selecting")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                setFavorite(!isFavorite)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFavorite ? "Remove \(destination.name) from favorites" : "Add \(destination.name) to favorites")
        }
        .help(destination.udid)
    }

    private var destinationIcon: String {
        switch destination.kind {
        case .localMac: "desktopcomputer"
        case .simulator: "iphone.gen3"
        case .physicalDevice: "iphone"
        }
    }
}

struct HealthBadge: View {
    let title: String
    let isHealthy: Bool
    let isEmpty: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isEmpty ? Color.secondary : (isHealthy ? Color.green : Color.orange))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum DestinationLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
}

struct DestinationPresentationGroup {
    let id: String
    let title: String
    let kind: DestinationKind
    let destinations: [Destination]
}

enum DestinationScope: String, CaseIterable, Identifiable {
    case all
    case favorites
    case mac
    case physical
    case simulators

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .mac: "Mac"
        case .physical: "Physical"
        case .simulators: "Simulators"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .mac: "desktopcomputer"
        case .physical: "iphone"
        case .simulators: "iphone.gen3"
        }
    }

    var help: String {
        switch self {
        case .all: "Show all destinations"
        case .favorites: "Show favorite destinations"
        case .mac: "Show Mac destinations"
        case .physical: "Show physical devices"
        case .simulators: "Show simulators"
        }
    }
}

struct DestinationScopeChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? XerTheme.action : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
                }
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct DestinationFilterToken: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(XerTheme.action)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(XerTheme.action.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Remove \(title) filter")
        .accessibilityLabel("Remove \(title) filter")
    }
}
