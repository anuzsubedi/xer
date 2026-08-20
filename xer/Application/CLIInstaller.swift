import AppKit
import Foundation

struct CLIInstallResult {
    let commandURL: URL
    let shellProfileURL: URL?
    let shellProfileUpdated: Bool
    let shellProfileCreated: Bool
}

enum CLIInstaller {
    static let commandName = "xer"
    static let bundledScriptName = "xer-cli"
    static let profileMarker = "# xer command"

    static var defaultInstallDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var installURL: URL {
        defaultInstallDirectory.appendingPathComponent(commandName, isDirectory: false)
    }

    static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: installURL.path) else {
            return false
        }
        guard let contents = try? String(contentsOf: installURL, encoding: .utf8) else {
            return false
        }
        return contents.contains("xer command stub")
            && contents.contains(Bundle.main.bundlePath)
    }

    static var installDirectoryIsOnPATH: Bool {
        pathEntries.contains(defaultInstallDirectory.path)
    }

    static var detectedShellProfileURL: URL? {
        shellConfiguration(for: loginShellName())?.profileURL
    }

    @discardableResult
    static func install() throws -> CLIInstallResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: defaultInstallDirectory,
            withIntermediateDirectories: true
        )

        guard let bundledScriptURL = Bundle.main.url(
            forResource: bundledScriptName,
            withExtension: nil
        ) else {
            throw CLIInstallerError.missingBundledScript
        }

        let stub = """
        #!/bin/bash
        # xer command stub
        export XER_APP="\(Bundle.main.bundlePath)"
        exec "\(bundledScriptURL.path)" "$@"
        """

        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }

        try stub.write(to: installURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: installURL.path
        )

        let profileUpdate = try configureShellProfileIfNeeded()

        return CLIInstallResult(
            commandURL: installURL,
            shellProfileURL: profileUpdate?.profileURL,
            shellProfileUpdated: profileUpdate?.updated ?? false,
            shellProfileCreated: profileUpdate?.created ?? false
        )
    }

    static func uninstall() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }
        try removeShellProfileEntryIfPresent()
    }

    static var shellSetupHint: String {
        let directory = defaultInstallDirectory.path
        if installDirectoryIsOnPATH {
            return directory
        }
        if let profileURL = detectedShellProfileURL {
            return """
            \(directory)

            Add this directory to \(profileURL.path):
            \(pathSetupLine(for: loginShellName()))
            """
        }
        return """
        \(directory)

        Add this directory to your shell PATH:
        \(pathSetupLine(for: loginShellName()))
        """
    }

    private struct ShellConfiguration {
        let profileURL: URL
        let setupBlock: String
    }

    private struct ProfileUpdate {
        let profileURL: URL
        let updated: Bool
        let created: Bool
    }

    private static func loginShellName() -> String {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return URL(fileURLWithPath: shellPath).lastPathComponent.lowercased()
    }

    private static func shellConfiguration(for shellName: String) -> ShellConfiguration? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch shellName {
        case "zsh":
            return ShellConfiguration(
                profileURL: home.appendingPathComponent(".zshrc"),
                setupBlock: """
                \(profileMarker)
                export PATH="$HOME/.local/bin:$PATH"
                """
            )
        case "bash":
            let bashProfile = home.appendingPathComponent(".bash_profile")
            let bashrc = home.appendingPathComponent(".bashrc")
            let profileURL = FileManager.default.fileExists(atPath: bashProfile.path)
                ? bashProfile
                : bashrc
            return ShellConfiguration(
                profileURL: profileURL,
                setupBlock: """
                \(profileMarker)
                export PATH="$HOME/.local/bin:$PATH"
                """
            )
        case "fish":
            return ShellConfiguration(
                profileURL: home.appendingPathComponent(".config/fish/config.fish"),
                setupBlock: """
                \(profileMarker)
                fish_add_path -m $HOME/.local/bin
                """
            )
        default:
            return ShellConfiguration(
                profileURL: home.appendingPathComponent(".profile"),
                setupBlock: """
                \(profileMarker)
                export PATH="$HOME/.local/bin:$PATH"
                """
            )
        }
    }

    private static func pathSetupLine(for shellName: String) -> String {
        switch shellName {
        case "fish":
            return "fish_add_path -m $HOME/.local/bin"
        default:
            return "export PATH=\"$HOME/.local/bin:$PATH\""
        }
    }

    private static func configureShellProfileIfNeeded() throws -> ProfileUpdate? {
        guard !profileAlreadyConfiguresPath() else { return nil }
        guard let configuration = shellConfiguration(for: loginShellName()) else { return nil }

        let fileManager = FileManager.default
        let profileURL = configuration.profileURL
        let created = !fileManager.fileExists(atPath: profileURL.path)

        if created {
            try fileManager.createDirectory(
                at: profileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var contents = created
            ? ""
            : (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""

        if contents.contains(profileMarker) || contentsContainsLocalBinPath(contents) {
            return ProfileUpdate(profileURL: profileURL, updated: false, created: created)
        }

        if !contents.isEmpty, !contents.hasSuffix("\n") {
            contents.append("\n")
        }
        if !contents.isEmpty {
            contents.append("\n")
        }
        contents.append(configuration.setupBlock)
        contents.append("\n")

        try contents.write(to: profileURL, atomically: true, encoding: .utf8)

        return ProfileUpdate(profileURL: profileURL, updated: true, created: created)
    }

    private static func removeShellProfileEntryIfPresent() throws {
        guard let configuration = shellConfiguration(for: loginShellName()) else { return }

        let profileURL = configuration.profileURL
        guard FileManager.default.fileExists(atPath: profileURL.path),
              var contents = try? String(contentsOf: profileURL, encoding: .utf8),
              contents.contains(profileMarker) else {
            return
        }

        contents = contents
            .replacingOccurrences(
                of: "\n\(profileMarker)\nexport PATH=\"$HOME/.local/bin:$PATH\"\n",
                with: "\n"
            )
            .replacingOccurrences(
                of: "\n\(profileMarker)\nfish_add_path -m $HOME/.local/bin\n",
                with: "\n"
            )
            .replacingOccurrences(
                of: "\(profileMarker)\nexport PATH=\"$HOME/.local/bin:$PATH\"\n",
                with: ""
            )
            .replacingOccurrences(
                of: "\(profileMarker)\nfish_add_path -m $HOME/.local/bin\n",
                with: ""
            )

        while contents.hasSuffix("\n\n\n") {
            contents.removeLast()
        }

        try contents.write(to: profileURL, atomically: true, encoding: .utf8)
    }

    private static func profileAlreadyConfiguresPath() -> Bool {
        guard let configuration = shellConfiguration(for: loginShellName()),
              let contents = try? String(contentsOf: configuration.profileURL, encoding: .utf8) else {
            return installDirectoryIsOnPATH
        }
        return contents.contains(profileMarker) || contentsContainsLocalBinPath(contents)
    }

    private static func contentsContainsLocalBinPath(_ contents: String) -> Bool {
        contents.contains("$HOME/.local/bin")
            || contents.contains("\(defaultInstallDirectory.path)")
    }

    private static var pathEntries: [String] {
        ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
    }
}

enum CLIInstallerError: LocalizedError {
    case missingBundledScript

    var errorDescription: String? {
        switch self {
        case .missingBundledScript:
            return "The bundled xer command script is missing from the application bundle."
        }
    }
}
