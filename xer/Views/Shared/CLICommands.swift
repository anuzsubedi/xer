import AppKit
import SwiftUI

extension ContentView {

    func installCLICommand() {
        do {
            let result = try CLIInstaller.install()
            cliInstallFailed = false

            var message = "Installed the xer command at \(result.commandURL.path)."

            if let profileURL = result.shellProfileURL {
                if result.shellProfileUpdated {
                    message += """

                    Updated \(profileURL.lastPathComponent) so ~/.local/bin is on your PATH.
                    Open a new terminal window, then use:
                    """
                } else if result.shellProfileCreated {
                    message += """

                    Created \(profileURL.path) with PATH setup.
                    Open a new terminal window, then use:
                    """
                } else {
                    message += """

                    \(profileURL.lastPathComponent) already includes ~/.local/bin.
                    Use:
                    """
                }
            } else if CLIInstaller.installDirectoryIsOnPATH {
                message += """

                Use:
                """
            } else {
                message += """

                Open a new terminal window, then use:
                """
            }

            message += """

            xer .
            xer run .
            """
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

    var terminalCommandMenu: some View {
        Menu {
            if CLIInstaller.isInstalled {
                Text("Installed at \(CLIInstaller.installURL.path)")
                Button("Reinstall xer Command") {
                    installCLICommand()
                }
                Button("Remove xer Command", role: .destructive) {
                    removeCLICommand()
                }
            } else {
                Button("Install xer Command…") {
                    installCLICommand()
                }
            }

            Divider()

            Button("Copy Install Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CLIInstaller.installURL.path, forType: .string)
            }

            if let profileURL = CLIInstaller.detectedShellProfileURL {
                Button("Copy Shell Profile Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(profileURL.path, forType: .string)
                }
            }
        } label: {
            Label("Terminal", systemImage: "terminal")
        }
        .help("Install or manage the xer terminal command")
        .accessibilityLabel("Terminal command menu")
    }

    var terminalCommandToolbarButton: some View {
        Menu {
            if CLIInstaller.isInstalled {
                Text("Installed at \(CLIInstaller.installURL.path)")
                Button("Reinstall xer Command") {
                    installCLICommand()
                }
                Button("Remove xer Command", role: .destructive) {
                    removeCLICommand()
                }
            } else {
                Button("Install xer Command…") {
                    installCLICommand()
                }
            }

            Divider()

            Button("Copy Install Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CLIInstaller.installURL.path, forType: .string)
            }

            if let profileURL = CLIInstaller.detectedShellProfileURL {
                Button("Copy Shell Profile Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(profileURL.path, forType: .string)
                }
            }
        } label: {
            Image(systemName: CLIInstaller.isInstalled ? "terminal.fill" : "terminal")
                .foregroundStyle(CLIInstaller.isInstalled ? XerTheme.action : .secondary)
        }
        .buttonStyle(.borderless)
        .help("Install or manage the xer terminal command")
        .accessibilityLabel("Terminal command menu")
    }
}
