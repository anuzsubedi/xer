import Foundation

enum UserFacingError {
    static func describe(_ error: Error) -> String {
        if error is CancellationError {
            return "Cancelled."
        }

        if let failure = error as? ToolFailure {
            let output = failure.output.xerTrimmed
            let lowercased = output.lowercased()
            if lowercased.contains("code signing")
                || lowercased.contains("codesign")
                || lowercased.contains("provisioning profile")
                || lowercased.contains("signing certificate")
                || lowercased.contains("no profiles") {
                return "Xcode could not sign this build. xer leaves signing enabled and does not weaken or bypass provisioning. Check the selected team, profile, certificate, device registration, and Developer Mode.\n\(tail(of: output))"
            }
            if lowercased.contains("developer mode")
                || lowercased.contains("trust this computer")
                || lowercased.contains("pair") {
                return "The connected device is not ready for developer operations. Confirm pairing/trust and enable Developer Mode if required.\n\(tail(of: output))"
            }
            if lowercased.contains("cannot be used within an app sandbox") {
                return "This build of xer is still running with App Sandbox enabled. Rebuild the xer target with ENABLE_APP_SANDBOX=NO; xcrun and xcodebuild cannot run from a sandboxed developer utility.\n\(tail(of: output))"
            }
            if lowercased.contains("unable to find utility")
                || lowercased.contains("command not found")
                || lowercased.contains("no such file or directory") {
                return "The Xcode command-line developer tools are unavailable. Install/select Xcode in Xcode > Settings > Locations, then retry.\n\(tail(of: output))"
            }
            return tail(of: output.isEmpty ? (failure.underlyingMessage ?? failure.localizedDescription) : output)
        }

        return error.localizedDescription.xerTrimmed
    }

    private static func tail(of text: String) -> String {
        let limit = 3_000
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit)
    }
}
