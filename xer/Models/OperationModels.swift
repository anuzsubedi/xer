import Foundation

struct OperationIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let recoverySuggestion: String?

    init(
        title: String = "Operation Failed",
        message: String,
        recoverySuggestion: String? = nil
    ) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    var summary: String {
        guard let newline = message.firstIndex(of: "\n") else { return message }
        return String(message[..<newline])
    }

    var details: String? {
        guard let newline = message.firstIndex(of: "\n") else { return nil }
        let detailsStart = message.index(after: newline)
        let remainder = String(message[detailsStart...]).xerTrimmed
        return remainder.isEmpty ? nil : remainder
    }
}

enum ProcessStream: String, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { terminationStatus == 0 }
    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct ProcessOutput: Sendable {
    let stream: ProcessStream
    let text: String
}

enum AppOperationState: Equatable, Sendable {
    case idle
    case importing
    case refreshingDestinations
    case refreshingSchemes
    case preparingBuild
    case building(completed: Int, total: Int)
    case installing(completed: Int, total: Int)
    case launching
    case running
    case cancelling
    case succeeded
    case failed(String)
    case cancelled

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .importing:
            return "Importing projects…"
        case .refreshingDestinations:
            return "Refreshing destinations…"
        case .refreshingSchemes:
            return "Refreshing schemes…"
        case .preparingBuild:
            return "Constructing build description…"
        case let .building(completed, total):
            return "Building \(completed)/\(total)…"
        case let .installing(completed, total):
            return "Installing \(completed)/\(total)…"
        case .launching:
            return "Launching…"
        case .running:
            return "Running"
        case .cancelling:
            return "Cancelling…"
        case .succeeded:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct ToolFailure: Error, LocalizedError, Sendable {
    let command: String
    let status: Int32?
    let output: String
    let underlyingMessage: String?

    var errorDescription: String? {
        if let underlyingMessage {
            return "\(command): \(underlyingMessage)"
        }
        if output.isEmpty {
            return "\(command) failed (exit \(status.map(String.init) ?? "unknown"))."
        }
        return "\(command) failed (exit \(status.map(String.init) ?? "unknown")): \(output)"
    }
}

struct AppFailure: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

extension String {
    var xerTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
