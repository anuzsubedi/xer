import Foundation

@MainActor
final class OperationController {
    var activeTask: Task<Void, Never>?
    var restartTask: Task<Void, Never>?

    var isBusy: Bool {
        activeTask != nil || restartTask != nil
    }

    func cancel(using tooling: DeveloperTooling) {
        activeTask?.cancel()
        restartTask?.cancel()
        tooling.cancelAll()
    }
}
