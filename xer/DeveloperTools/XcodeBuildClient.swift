import AppKit
import Foundation

extension DeveloperTooling {

    func listSchemes(
        for project: ImportedProject,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> [SharedScheme] {
        let arguments = Self.schemeListArguments(for: project)
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        guard let object = Self.jsonObject(from: result.stdout) else {
            throw AppFailure(message: "xcodebuild returned an unreadable scheme list for \(project.displayName).")
        }

        return Self.schemeNames(in: object)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(SharedScheme.init(name:))
    }

    func listSchemeRunDestinations(
        for project: ImportedProject,
        scheme: String,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> [SchemeRunDestination] {
        let arguments = Self.showDestinationsArguments(for: project, scheme: scheme)
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)
        return Self.schemeRunDestinations(in: result.combinedOutput)
    }

    func build(
        project: ImportedProject,
        scheme: String,
        configuration: String,
        destination: Destination,
        derivedDataURL: URL,
        outputHandler: ProcessRunner.OutputHandler? = nil
    ) async throws -> BuildArtifact {
        try Task.checkCancellation()

        guard !scheme.xerTrimmed.isEmpty else {
            throw AppFailure(message: "Choose a scheme before building.")
        }
        guard destination.isAvailable else {
            throw AppFailure(message: "The selected destination is not currently available.")
        }
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw AppFailure(message: "The imported project no longer exists at \(project.path).")
        }

        try FileManager.default.createDirectory(
            at: derivedDataURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let arguments = Self.buildArguments(
            for: project,
            scheme: scheme,
            configuration: configuration,
            destination: destination,
            derivedDataURL: derivedDataURL
        )
        let result = try await invoke(arguments, outputHandler: outputHandler)
        try check(result, arguments: arguments)

        let appURL = try findBuiltApplication(
            in: derivedDataURL,
            preferredName: scheme
        )
        let metadata = try Self.localAppMetadata(for: appURL)
        return BuildArtifact(
            appURL: appURL,
            bundleIdentifier: metadata.bundleIdentifier,
            destination: destination,
            displayName: metadata.displayName,
            appIcon: metadata.icon
        )
    }
}
