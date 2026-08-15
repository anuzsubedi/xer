import Foundation

struct BuildContext: Sendable {
    let project: ImportedProject
    let scheme: String
    let destinations: [Destination]
    let configuration: String
    let cleanBuildFolder: Bool
}

struct BuildOutcome: Sendable {
    let destination: Destination
    let artifact: BuildArtifact?
    let errorMessage: String?
}

struct DeployOutcome: Sendable {
    let destination: Destination
    let artifact: BuildArtifact?
    let errorMessage: String?
}

struct LaunchOutcome: Sendable {
    let destination: Destination
    let errorMessage: String?
}

extension Array {
    func batches(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var batches: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            batches.append(Array(self[index..<end]))
            index = end
        }
        return batches
    }
}
