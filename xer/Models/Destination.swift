import Foundation

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
