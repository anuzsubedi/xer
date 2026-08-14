import Darwin
import Foundation

/// Runs developer tools directly. Arguments are passed to Foundation.Process as
/// an array; no shell is involved, so project paths and scheme names cannot
/// become shell syntax accidentally.
final class ProcessRunner: @unchecked Sendable {
    typealias OutputHandler = @Sendable (ProcessOutput) -> Void

    private let lock = NSLock()
    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledProcesses: Set<UUID> = []

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectoryURL: URL? = nil,
        outputHandler: OutputHandler? = nil
    ) async throws -> ProcessResult {
        let token = UUID()
        try Task.checkCancellation()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let accumulator = ProcessOutputAccumulator()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.currentDirectoryURL = workingDirectoryURL

                if let environment {
                    var mergedEnvironment = ProcessInfo.processInfo.environment
                    for (key, value) in environment {
                        mergedEnvironment[key] = value
                    }
                    process.environment = mergedEnvironment
                }

                // Keep process output delivery independent from the launch
                // command's lifetime. A console-attached simctl/devicectl
                // process can run for the entire app session, so every chunk is
                // accumulated and forwarded until the child actually exits.
                let handleOutput: @Sendable (ProcessStream, Data) -> Void = { stream, data in
                    guard !data.isEmpty else { return }
                    accumulator.append(data, stream: stream)
                    guard let outputHandler else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    guard !text.isEmpty else { return }
                    outputHandler(ProcessOutput(stream: stream, text: text))
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    handleOutput(.standardOutput, handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    handleOutput(.standardError, handle.availableData)
                }

                process.terminationHandler = { [weak self] terminatedProcess in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // A readability callback may not have drained the final bytes
                    // before terminationHandler runs. Drain both pipes once more.
                    handleOutput(.standardOutput, stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    handleOutput(.standardError, stderrPipe.fileHandleForReading.readDataToEndOfFile())

                    guard let self else {
                        continuation.resume(returning: ProcessResult(
                            terminationStatus: terminatedProcess.terminationStatus,
                            stdout: accumulator.text(for: .standardOutput),
                            stderr: accumulator.text(for: .standardError)
                        ))
                        return
                    }

                    self.finish(
                        token: token,
                        process: terminatedProcess,
                        accumulator: accumulator,
                        continuation: continuation
                    )
                }

                self.lock.lock()
                self.activeProcesses[token] = process
                self.lock.unlock()

                do {
                    try process.run()
                    // Cancellation can arrive between registration and run().
                    if Task.isCancelled {
                        self.cancel(token)
                    }
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    self.remove(token)
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: { [weak self] in
            self?.cancel(token)
        })
    }

    func cancelAll() {
        lock.lock()
        let tokens = Array(activeProcesses.keys)
        lock.unlock()
        tokens.forEach(cancel)
    }

    private func cancel(_ token: UUID) {
        lock.lock()
        guard let process = activeProcesses[token] else {
            lock.unlock()
            return
        }
        cancelledProcesses.insert(token)
        lock.unlock()

        guard process.isRunning else { return }
        process.terminate()

        // xcodebuild can leave helper processes behind while it unwinds. A
        // delayed hard kill keeps cancellation deterministic without using a
        // shell or killing unrelated processes.
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    private func finish(
        token: UUID,
        process: Process,
        accumulator: ProcessOutputAccumulator,
        continuation: CheckedContinuation<ProcessResult, Error>
    ) {
        lock.lock()
        let wasCancelled = cancelledProcesses.remove(token) != nil
        let wasActive = activeProcesses.removeValue(forKey: token) != nil
        lock.unlock()

        // A launch error may have already removed the token. This guard makes
        // termination-handler and launch-error races harmless.
        guard wasActive else { return }

        if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(returning: ProcessResult(
                terminationStatus: process.terminationStatus,
                stdout: accumulator.text(for: .standardOutput),
                stderr: accumulator.text(for: .standardError)
            ))
        }
    }

    private func remove(_ token: UUID) {
        lock.lock()
        activeProcesses.removeValue(forKey: token)
        cancelledProcesses.remove(token)
        lock.unlock()
    }

    /// Returns a shell-safe display string for logs only. The command is never
    /// executed through this string; Process receives the original argv array.
    static func displayCommand(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments).map { argument in
            let escaped = argument.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }.joined(separator: " ")
    }
}

private final class ProcessOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, stream: ProcessStream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .standardOutput:
            stdout.append(data)
        case .standardError:
            stderr.append(data)
        }
    }

    func text(for stream: ProcessStream) -> String {
        lock.lock()
        let data: Data
        switch stream {
        case .standardOutput:
            data = stdout
        case .standardError:
            data = stderr
        }
        lock.unlock()

        return String(decoding: data, as: UTF8.self)
    }
}
