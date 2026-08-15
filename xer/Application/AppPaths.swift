import CryptoKit
import Foundation

enum AppPaths {
    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xer", isDirectory: true)
    }

    static var derivedDataRoot: URL {
        applicationSupportRoot.appendingPathComponent("DerivedData", isDirectory: true)
    }

    static func derivedDataURL(projectPath: String, scheme: String, destinationID: String) -> URL {
        derivedDataRoot
            .appendingPathComponent(stableComponent(projectPath), isDirectory: true)
            .appendingPathComponent(stableComponent(scheme), isDirectory: true)
            .appendingPathComponent(stableComponent(destinationID), isDirectory: true)
    }

    private static func stableComponent(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
