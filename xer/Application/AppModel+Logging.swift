import AppKit
import Foundation

extension AppModel {

    func clearLogs() {
        logStore.clear()
    }

    func clearError() {
        lastIssue = nil
    }

    func appendLog(
        _ level: LogEntry.Level,
        _ message: String,
        preserveWhitespace: Bool = false
    ) {
        logStore.append(
            level: level,
            message: message,
            preserveWhitespace: preserveWhitespace
        )
    }

    func presentError(_ message: String) {
        lastIssue = OperationIssue(message: message)
        appendLog(.error, message)
    }

    func presentOperationFailure(_ message: String) {
        let normalized = message.xerTrimmed.isEmpty ? "The operation failed without a diagnostic." : message.xerTrimmed
        lastIssue = OperationIssue(message: normalized)
        operationState = .failed(normalized)
        appendLog(.error, normalized)
    }
}
