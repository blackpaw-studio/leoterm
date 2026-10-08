#if DEBUG
import Foundation

/// DEBUG builds only: the `"control"` key of the `LEO_ATTENTION_FIXTURE`
/// file (B-262) makes the four control routes answer as a daemon that
/// refuses the caller, without the request reaching any daemon. `"deny"` is
/// a 403 (a non-operator token), `"unavailable"` a 503 (web disabled). It
/// lets the inline error and the disabled controls be seen with the real
/// socket daemon, which never checks a token.
enum LeoControlFixtureMode: String, Equatable, Sendable {
    case deny, unavailable

    var response: LeoHTTPResponse {
        switch self {
        case .deny: LeoHTTPResponse(status: 403, body: Data(#"{"ok":false,"error":"operator token required"}"#.utf8))
        case .unavailable: LeoHTTPResponse(status: 503, body: Data(#"{"ok":false,"error":"agent control is unavailable: the web server is not running (web.enabled)"}"#.utf8))
        }
    }
}

struct LeoControlFixtureTransport: LeoDaemonTransport {
    let base: any LeoDaemonTransport
    let mode: LeoControlFixtureMode

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        guard Self.isControl(request) else { return try await base.send(request, socketPath: socketPath, timeout: timeout) }
        return mode.response
    }

    static func isControl(_ request: LeoHTTPRequest) -> Bool {
        guard request.method == "POST" else { return false }
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0].isEmpty && parts[1] == "agents"
            && LeoControlVerb.allCases.contains { $0.rawValue == parts[3] }
    }
}
#endif
