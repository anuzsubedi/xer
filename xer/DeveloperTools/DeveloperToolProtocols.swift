import Foundation

protocol BuildProviding: Sendable {
    func build(
        project: ImportedProject,
        scheme: String,
        configuration: String,
        destination: Destination,
        derivedDataURL: URL,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws -> BuildArtifact
}

protocol AppDeploying: Sendable {
    func install(
        artifact: BuildArtifact,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws

    func launch(
        artifact: BuildArtifact,
        attachConsole: Bool,
        includeUnifiedLogs: Bool,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws
}

extension DeveloperTooling: BuildProviding, AppDeploying {}
