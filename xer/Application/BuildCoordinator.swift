import Foundation

final class BuildCoordinator: Sendable {
    private let builder: any BuildProviding
    private let deployer: any AppDeploying

    init(tooling: DeveloperTooling) {
        self.builder = tooling
        self.deployer = tooling
    }

    func build(
        project: ImportedProject,
        scheme: String,
        configuration: String,
        destination: Destination,
        derivedDataURL: URL,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws -> BuildArtifact {
        try await builder.build(
            project: project,
            scheme: scheme,
            configuration: configuration,
            destination: destination,
            derivedDataURL: derivedDataURL,
            outputHandler: outputHandler
        )
    }

    func install(
        artifact: BuildArtifact,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws {
        try await deployer.install(artifact: artifact, outputHandler: outputHandler)
    }

    func launch(
        artifact: BuildArtifact,
        attachConsole: Bool,
        includeUnifiedLogs: Bool,
        outputHandler: ProcessRunner.OutputHandler?
    ) async throws {
        try await deployer.launch(
            artifact: artifact,
            attachConsole: attachConsole,
            includeUnifiedLogs: includeUnifiedLogs,
            outputHandler: outputHandler
        )
    }
}
