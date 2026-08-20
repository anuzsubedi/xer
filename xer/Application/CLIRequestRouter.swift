import Combine
import Foundation

@MainActor
final class CLIRequestRouter: ObservableObject {
    @Published private(set) var pendingRequest: CLIRequest?

    func deliver(_ request: CLIRequest) {
        pendingRequest = request
    }

    func consumePendingRequest() -> CLIRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}

enum CLIRouteParser {
    static func request(from url: URL) -> CLIRequest? {
        guard url.scheme?.lowercased() == "xer" else { return nil }

        let action: String
        if let host = url.host?.lowercased(), host == "open" || host == "run" {
            action = host
        } else if url.path == "/open" || url.path == "/run" {
            action = String(url.path.dropFirst())
        } else {
            action = "open"
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !rawPath.isEmpty else {
            return nil
        }

        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        switch action {
        case "run":
            return .run(path: decodedPath)
        default:
            return .open(path: decodedPath)
        }
    }
}
