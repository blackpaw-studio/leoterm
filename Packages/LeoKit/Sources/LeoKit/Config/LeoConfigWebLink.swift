import Foundation

/// The "Edit in the web UI" link for a field the app can't render (plan D4).
/// It goes to the machine's first `web.public_urls` entry, else to a
/// routable bind address and port, else nowhere: a web UI bound to loopback
/// on a tunnelled machine can't be reached from here, so the row says so in
/// text instead.
public enum LeoConfigWebLink {
    public static let defaultPort = 8370
    public static let defaultBind = "127.0.0.1"
    /// The web UI's settings pages hang off this path.
    public static let configPath = "/config"

    /// `machineHost` stands in for a wildcard bind (`0.0.0.0`, `::`), which
    /// says the daemon listens everywhere but not where to reach it.
    public static func url(web: LeoConfigDocument?, machineHost: String? = nil) -> URL? {
        guard let web, web.values["enabled"]?.boolValue != false else { return nil }
        let base = publicURL(in: web) ?? boundURL(in: web, machineHost: machineHost)
        return base.flatMap { URL(string: $0.absoluteString.trimmingTrailingSlash + configPath) }
    }

    private static func publicURL(in web: LeoConfigDocument) -> URL? {
        (web.values["public_urls"]?.stringList ?? []).lazy.compactMap { text -> URL? in
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }.first
    }

    private static func boundURL(in web: LeoConfigDocument, machineHost: String?) -> URL? {
        let bind = web.values["bind"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? defaultBind
        let port = web.values["port"]?.intValue ?? defaultPort
        guard !isLoopback(bind) else { return nil }
        guard let host = isWildcard(bind) ? machineHost : bind, !host.isEmpty else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(bracketed):\(port)")
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
    }

    private static func isWildcard(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::"
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
