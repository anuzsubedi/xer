import AppKit
import Foundation

extension DeveloperTooling {
    static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return jsonObject(from: data)
    }

    static func jsonObject(from data: Data) -> Any? {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        // xcodebuild occasionally prefixes diagnostics around machine-readable
        // output. Recover the first complete JSON object without treating any
        // diagnostic text as JSON.
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let candidate = String(text[start...])
        return try? JSONSerialization.jsonObject(with: Data(candidate.utf8))
    }

    static func schemeRunDestinations(in text: String) -> [SchemeRunDestination] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            schemeRunDestination(in: String(line))
        }
    }

    static func schemeRunDestination(in line: String) -> SchemeRunDestination? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        var fields: [String: String] = [:]
        for part in inner.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let colon = piece.firstIndex(of: ":") else { continue }
            let key = piece[..<colon].trimmingCharacters(in: .whitespaces)
            let value = piece[piece.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                fields[key] = value
            }
        }
        guard let platform = fields["platform"], !platform.isEmpty else { return nil }
        return SchemeRunDestination(
            platform: platform,
            architecture: fields["arch"],
            variant: fields["variant"],
            id: fields["id"],
            osVersion: fields["OS"],
            name: fields["name"]
        )
    }

    static func schemeNames(in object: Any) -> [String] {
        var names = Set<String>()

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let schemes = dictionary["schemes"] as? [Any] {
                    for scheme in schemes {
                        if let name = scheme as? String, !name.isEmpty {
                            names.insert(name)
                        }
                    }
                }
                for child in dictionary.values { visit(child) }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }

        visit(object)
        return Array(names)
    }

    static func simulatorDestinations(from object: Any) throws -> [Destination] {
        guard let root = object as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else {
            throw AppFailure(message: "simctl returned an unreadable simulator list.")
        }

        var destinations: [Destination] = []
        for (runtimeIdentifier, value) in devicesByRuntime {
            guard let devices = value as? [[String: Any]] else { continue }
            for device in devices {
                let isAvailable = Self.boolValue(device["isAvailable"]) ?? true
                guard isAvailable,
                      let udid = stringValue(device, keys: ["udid"]),
                      let name = stringValue(device, keys: ["name"]) else {
                    continue
                }

                let runtime = Self.runtimeInformation(from: runtimeIdentifier)
                let platform = stringValue(device, keys: ["platform"]) ?? runtime.platform
                let osVersion = stringValue(device, keys: ["osVersion"]) ?? runtime.version
                let state = stringValue(device, keys: ["state"])
                let modelName = stringValue(device, keys: ["deviceTypeIdentifier", "modelIdentifier"])
                destinations.append(Destination(
                    udid: udid,
                    name: name,
                    platform: platform,
                    osVersion: osVersion,
                    state: state,
                    kind: .simulator,
                    isAvailable: true,
                    modelName: modelName
                ))
            }
        }
        return Self.deduplicated(destinations)
    }

    static func physicalDestinations(from object: Any) throws -> [Destination] {
        guard let root = object as? [String: Any],
              let result = dictionaryValue(root["result"]),
              let rawDevices = result["devices"] as? [[String: Any]] else {
            throw AppFailure(message: "devicectl returned an unreadable connected-device list.")
        }

        var destinations: [Destination] = []
        for rawDevice in rawDevices {
            let deviceProperties = dictionaryValue(rawDevice["deviceProperties"]) ?? [:]
            let hardwareProperties = dictionaryValue(rawDevice["hardwareProperties"]) ?? [:]
            let connectionProperties = dictionaryValue(rawDevice["connectionProperties"]) ?? [:]

            // devicectl also reports CoreSimulator devices. Simulators come from
            // simctl, so do not duplicate them in the physical-device section.
            let reality = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["reality", "deviceReality"]
            )?.lowercased()
            let provider = firstString(
                in: [deviceProperties, hardwareProperties, rawDevice],
                keys: ["provider"]
            )?.lowercased()
            let visibilityClass = stringValue(rawDevice, keys: ["visibilityClass"])?.lowercased()
            if reality == "simulated"
                || provider?.contains("simulator") == true
                || visibilityClass == "simulators" {
                continue
            }

            // xcodebuild destinations use the hardware UDID. devicectl exposes a
            // CoreDevice UUID at the top level, so prefer hardwareProperties.udid.
            let udid = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["udid", "deviceIdentifier", "identifier"]
            )
            guard let udid, !udid.isEmpty else { continue }

            let connectionState = firstString(
                in: [connectionProperties, rawDevice, deviceProperties],
                keys: ["connectionState", "connectionStatus", "state", "status", "tunnelState"]
            )
            let pairingState = firstString(
                in: [connectionProperties, rawDevice, deviceProperties],
                keys: ["pairingState", "pairingStatus"]
            )
            let developerMode = firstString(
                in: [deviceProperties, rawDevice],
                keys: ["developerModeStatus", "developerMode"]
            )
            let isAvailable = isUsableDevice(
                connectionState: connectionState,
                pairingState: pairingState,
                developerMode: developerMode
            )

            let name = firstString(
                in: [deviceProperties, rawDevice, hardwareProperties],
                keys: ["name", "deviceName", "displayName", "marketingName"]
            ) ?? "Device \(udid.prefix(8))"
            let platform = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["platform", "platformName", "productType"]
            ) ?? "Apple device"
            let osVersion = firstString(
                in: [deviceProperties, rawDevice, hardwareProperties],
                keys: ["osVersion", "osVersionNumber", "operatingSystemVersion", "version"]
            )
            let state = connectionState
                ?? pairingState
                ?? developerMode
                ?? "connected"
            let modelName = firstString(
                in: [hardwareProperties, deviceProperties, rawDevice],
                keys: ["marketingName", "modelName", "productType", "hardwareModel"]
            )
            let batteryLevel = firstNumber(
                in: [deviceProperties, hardwareProperties, rawDevice],
                keys: ["batteryLevel", "batteryPercentage", "batteryCurrentCapacity"]
            ).map { value in
                let percentage = value <= 1 ? value * 100 : value
                return min(max(Int(percentage.rounded()), 0), 100)
            }

            destinations.append(Destination(
                udid: udid,
                name: name,
                platform: platform,
                osVersion: osVersion,
                state: state,
                kind: .physicalDevice,
                isAvailable: isAvailable,
                modelName: modelName,
                batteryLevel: batteryLevel
            ))
        }

        return deduplicated(destinations)
    }

    static func bundleIdentifier(for appURL: URL) throws -> String {
        let infoURL = infoPlistURL(for: appURL)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.xerTrimmed.isEmpty else {
            throw AppFailure(message: "The built app at \(appURL.path) has no CFBundleIdentifier.")
        }
        return identifier
    }

    static func infoPlistURL(for appURL: URL) -> URL {
        let macOSInfoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: macOSInfoURL.path) {
            return macOSInfoURL
        }
        return appURL.appendingPathComponent("Info.plist")
    }

    static func localMacExecutableURL(for appURL: URL) throws -> URL {
        let infoURL = infoPlistURL(for: appURL)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let executableName = plist["CFBundleExecutable"] as? String,
              !executableName.xerTrimmed.isEmpty else {
            throw AppFailure(message: "The built Mac app has no CFBundleExecutable and cannot be launched.")
        }
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppFailure(message: "The built Mac app executable was not found at \(executableURL.path).")
        }
        return executableURL
    }
}

struct RuntimeInformation {
    let platform: String
    let version: String?
}

func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func firstString(in dictionaries: [[String: Any]], keys: [String]) -> String? {
    for dictionary in dictionaries {
        if let value = stringValue(dictionary, keys: keys) {
            return value
        }
    }
    return nil
}

func firstNumber(in dictionaries: [[String: Any]], keys: [String]) -> Double? {
    for dictionary in dictionaries {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.doubleValue
            }
            if let text = dictionary[key] as? String, let number = Double(text) {
                return number
            }
        }
    }
    return nil
}

func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = dictionary[key] as? String, !value.xerTrimmed.isEmpty {
            return value
        }
    }
    return nil
}

extension DeveloperTooling {
    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "available": return true
            case "false", "no", "unavailable": return false
            default: return nil
            }
        }
        return nil
    }
}
