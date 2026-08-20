import AppKit
import Foundation

enum CLIRequest: Equatable, Sendable {
    case open(path: String)
    case run(path: String)
}

extension AppModel {

    func handleCLIRequest(_ request: CLIRequest) {
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch request {
            case .open(let path):
                await self.handleOpenCLIRequest(path: path)
            case .run(let path):
                await self.handleRunCLIRequest(path: path)
            }
            self.operationTask = nil
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
        await performImport(from: importRoot)

        if let imported = discovery.preferredProject(in: projects, for: fileURL) {
            selectProject(imported.id)
        } else if let importRootProject = projects.first(where: { $0.path == importRoot.standardizedFileURL.path }) {
            selectProject(importRootProject.id)
        }

        activateApplicationWindow()
        await loadSchemesForSelectedProjectIfNeeded()
    }

    func handleRunCLIRequest(path: String) async {
        let fileURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            presentError("The selected path no longer exists at \(fileURL.path).")
            activateApplicationWindow()
            return
        }

        guard discovery.resolveImportRoot(for: fileURL) != nil else {
            presentError("No .xcworkspace or .xcodeproj packages were found in or above \(fileURL.path).")
            activateApplicationWindow()
            return
        }

        guard let project = discovery.preferredProject(in: projects, for: fileURL) else {
            presentError("This project is not imported yet. Run 'xer .' from the project folder first.")
            activateApplicationWindow()
            return
        }

        selectProject(project.id)
        activateApplicationWindow()
        await loadSchemesForSelectedProjectIfNeeded()

        guard project.isTrusted else {
            presentError("Trust \(project.displayName) in xer before running it from the terminal.")
            return
        }
        guard selectedSchemeName?.isEmpty == false else {
            presentError("Select a shared scheme in xer before running this project from the terminal.")
            return
        }
        guard !selectedDestinations.isEmpty else {
            presentError("Select at least one ready destination in xer before running this project from the terminal.")
            return
        }

        appendLog(.command, "Run requested from the xer command for \(project.displayName).")
        runOrRestart()
    }

    func activateApplicationWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}
