import AppKit
import Foundation

enum CLIRequest: Equatable, Sendable {
    case open(path: String)
    case refresh

    var bringsApplicationToFront: Bool {
        switch self {
        case .open:
            true
        case .refresh:
            false
        }
    }
}

extension AppModel {

    func handleCLIRequest(_ request: CLIRequest) {
        switch request {
        case .open(let path):
            operationTask?.cancel()
            operationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleOpenCLIRequest(path: path)
                self.operationTask = nil
            }
        case .refresh:
            handleRefreshCLIRequest()
        }
    }

    func handleOpenCLIRequest(path: String) async {
        let fileURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            presentError("The selected path no longer exists at \(fileURL.path).")
            activateApplicationWindow()
            return
        }

        guard let importRoot = discovery.resolveImportRoot(for: fileURL) else {
            presentError("No .xcworkspace or .xcodeproj packages were found in or above \(fileURL.path).")
            activateApplicationWindow()
            return
        }

        if let existing = discovery.preferredProject(in: projects, for: fileURL) {
            selectProject(existing.id)
            appendLog(.info, "Opened \(existing.displayName) from the xer command.")
            activateApplicationWindow()
            await loadSchemesForSelectedProjectIfNeeded()
            return
        }

        appendLog(.command, "Opening \(importRoot.path) from the xer command.")
        let mode: ProjectImportMode = discovery.kind(of: importRoot) == nil ? .folder : .project
        await performImport(from: importRoot, mode: mode)

        if let imported = discovery.preferredProject(in: projects, for: fileURL) {
            selectProject(imported.id)
        } else if let importRootProject = projects.first(where: { $0.path == importRoot.standardizedFileURL.path }) {
            selectProject(importRootProject.id)
        }

        activateApplicationWindow()
        await loadSchemesForSelectedProjectIfNeeded()
    }

    func handleRefreshCLIRequest() {
        guard isAppActive else {
            appendLog(.info, "No current build running.")
            return
        }

        appendLog(.info, "Refreshing app from the xer command.")
        runOrRestart()
    }

    func activateApplicationWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}
