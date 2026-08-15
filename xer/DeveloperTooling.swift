import AppKit
import Foundation

/// The command-line surface used by xer. Apple developer commands are sent to
/// xcrun and local Mac apps are launched from their bundle executable. Every
/// invocation uses an argv array; no shell parses paths or scheme names.
final class DeveloperTooling: Sendable {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    let processRunner: ProcessRunner
    let xcrunURL: URL

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        xcrunURL: URL = DeveloperTooling.executableURL
    ) {
        self.processRunner = processRunner
        self.xcrunURL = xcrunURL
    }

    func cancelAll() {
        processRunner.cancelAll()
    }
}
