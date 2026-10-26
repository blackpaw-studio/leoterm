import Foundation

/// Asks the OS about loopback TCP ports. A seam so tests never bind a real
/// port; `LeoLoopbackPortProber` is the real one.
protocol LeoPortProbing: Sendable {
    /// True when nothing is bound to `127.0.0.1:port`.
    func isFree(_ port: Int) -> Bool
    /// True when something accepts connections on `127.0.0.1:port`.
    func isListening(_ port: Int) -> Bool
    /// A currently free ephemeral port (ssh rejects `-L` port 0, so the app
    /// has to choose).
    func pickFreePort() throws -> Int
}

/// Pure decisions for browsing `localhost` on a remote machine: which URLs
/// need a forward, which local port carries it, and the URL rewrites in both
/// directions. Holds no forward state; `LeoPortForwards` owns that.
struct LeoPortForwardPlanner: Sendable {
    static let validPorts = 1...65_535

    /// Only remote machines forward; the local machine's `localhost` is
    /// already the right one.
    let isRemote: Bool
    let prober: any LeoPortProbing

    /// The remote port `url` needs forwarded, or nil when it needs no
    /// forward: a local machine, a non-loopback host, or a non-web scheme.
    func remotePort(for url: URL) -> Int? {
        guard isRemote, Self.isLoopback(url), let port = Self.effectivePort(of: url) else { return nil }
        return Self.validPorts.contains(port) ? port : nil
    }

    /// The same port as the remote when it's free (so origin, cookies and
    /// OAuth redirects match), else a free one. `avoiding` holds local ports
    /// already carrying another forward.
    func localPort(forRemote remotePort: Int, avoiding: Set<Int>) throws -> Int {
        if !avoiding.contains(remotePort), prober.isFree(remotePort) { return remotePort }
        // A prober that keeps returning avoided ports must not spin forever.
        for _ in 0..<Self.maxPickAttempts {
            let picked = try prober.pickFreePort()
            if !avoiding.contains(picked) { return picked }
        }
        throw LeoPortForwardError.noFreePort
    }

    /// Remote-terms URL → the URL the web view loads. `mapping` is
    /// remote port → local port.
    func toLocal(_ url: URL, using mapping: [Int: Int]) -> URL {
        guard isRemote, Self.isLoopback(url), let port = Self.effectivePort(of: url), let local = mapping[port] else { return url }
        return Self.rewrite(url, port: local)
    }

    /// The web view's URL → remote terms. `mapping` is local port → remote
    /// port.
    func toRemote(_ url: URL, using mapping: [Int: Int]) -> URL {
        guard isRemote, Self.isLoopback(url), let port = Self.effectivePort(of: url), let remote = mapping[port] else { return url }
        return Self.rewrite(url, port: remote)
    }

    private static let maxPickAttempts = 8
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// The forward listens on IPv4 loopback only, so an IPv6 host is
    /// rewritten to `127.0.0.1`. A rewrite that changes nothing returns the
    /// URL as given.
    private static func rewrite(_ url: URL, port: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if let host = components.host, host == "::1" || host == "[::1]" { components.host = "127.0.0.1" }
        if port != effectivePort(of: url) { components.port = port }
        return components.url ?? url
    }
}
