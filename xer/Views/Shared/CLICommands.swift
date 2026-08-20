import AppKit
import SwiftUI

extension ContentView {

    var cliInstallAlertTitle: String {
        if cliInstallFailed {
            return "Could Not Update Command"
        }
        if cliInstallMessage?.hasPrefix("Removed") == true {
            return "xer Command Removed"
        }
        return "xer Command Installed"
    }

    func installCLICommand() {
        do {
            let result = try CLIInstaller.install()
            cliInstallFailed = false
            cliCommandRevision += 1

            var message = "Installed the xer command at \(result.commandURL.path)."

            if let profileURL = result.shellProfileURL {
                if result.shellProfileUpdated {
                    message += """

                    Updated \(profileURL.lastPathComponent) so ~/.local/bin is on your PATH.
                    Open a new terminal window, then use xer . and xer refresh.
                    """
                } else if result.shellProfileCreated {
                    message += """

                    Created \(profileURL.path) with PATH setup.
                    Open a new terminal window, then use xer . and xer refresh.
                    """
                } else {
                    message += """

                    \(profileURL.lastPathComponent) already includes ~/.local/bin.
                    """
                }
            } else if !CLIInstaller.installDirectoryIsOnPATH {
                message += """

                Open a new terminal window so ~/.local/bin is on your PATH.
                """
            }

            if showTerminalCommands {
                return
            }
            cliInstallMessage = message
        } catch {
            cliInstallFailed = true
            cliInstallMessage = error.localizedDescription
        }
    }

    func removeCLICommand() {
        do {
            try CLIInstaller.uninstall()
            cliInstallFailed = false
            cliCommandRevision += 1
            if showTerminalCommands {
                return
            }
            if let profileURL = CLIInstaller.detectedShellProfileURL {
                cliInstallMessage = """
                Removed the xer command and its PATH entry from \(profileURL.path).
                Open a new terminal window for the change to take effect.
                """
            } else {
                cliInstallMessage = "Removed the xer command from \(CLIInstaller.installURL.path)."
            }
        } catch {
            cliInstallFailed = true
            cliInstallMessage = error.localizedDescription
        }
    }
}

struct XerMenuActions {
    let isBusy: Bool
    let isCommandInstalled: Bool
    let importFolder: () -> Void
    let addProject: () -> Void
    let installCommand: () -> Void
    let removeCommand: () -> Void
    let showTerminalCommands: () -> Void
}

private struct XerMenuActionsKey: FocusedValueKey {
    typealias Value = XerMenuActions
}

extension FocusedValues {
    var xerMenuActions: XerMenuActions? {
        get { self[XerMenuActionsKey.self] }
        set { self[XerMenuActionsKey.self] = newValue }
    }
}

struct XerCommands: Commands {
    @FocusedValue(\.xerMenuActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Folder…") {
                actions?.importFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(actions?.isBusy != false)

            Button("Add Project…") {
                actions?.addProject()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(actions?.isBusy != false)
        }
        CommandGroup(after: .appInfo) {
            Button(actions?.isCommandInstalled == true ? "Reinstall Terminal Command" : "Install Terminal Command") {
                actions?.installCommand()
            }
            if actions?.isCommandInstalled == true {
                Button("Remove Terminal Command") {
                    actions?.removeCommand()
                }
            }
        }
        CommandGroup(after: .help) {
            Button("Terminal Commands…") {
                actions?.showTerminalCommands()
            }
        }
    }
}

struct TerminalCommandsSheet: View {
    let isInstalled: Bool
    let installPath: String
    let install: () -> Void
    let remove: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal Commands")
                        .font(.title2.weight(.semibold))
                    Text("Use these from Terminal while xer is running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isInstalled ? "Installed" : "Not installed")
                            .font(.headline)
                        Text(isInstalled
                             ? installPath
                             : "Install once so Terminal can talk to xer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if isInstalled {
                        Button("Reinstall", action: install)
                        Button("Remove", role: .destructive, action: remove)
                    } else {
                        Button("Install…", action: install)
                            .keyboardShortcut(.defaultAction)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(CLIInstaller.documentedCommands) { command in
                        CLICommandRow(command: command)
                    }
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
    }
}

private struct CLICommandRow: View {
    let command: CLIDocumentedCommand

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(command.invocation)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                Text(command.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command.invocation, forType: .string)
            }
            .help("Copy \(command.invocation)")
        }
        .padding(12)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(command.invocation). \(command.summary)")
    }
}
