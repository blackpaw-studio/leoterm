import Foundation

/// Which URLs an agent browser may load: `http`, `https` and `about:blank`.
public enum LeoBrowserURLPolicy {
    /// `localhost:3000/path`: a host and port with no scheme, which URL parsing
    /// would otherwise read as scheme `localhost`.
    private static let hostAndPort = #"^[A-Za-z0-9.\-]+:\d{1,5}(?:[/?#].*)?$"#

    /// Parses an agent-supplied URL. Throws `scheme_not_allowed` for any other
    /// scheme (or none), `invalid_args` for text that isn't a URL.
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: hostAndPort, options: .regularExpression) != nil {
            throw LeoBrowserError(.schemeNotAllowed, "URL is missing http:// or https://. Use a full URL such as http://\(trimmed)")
        }
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw LeoBrowserError.invalidArgs("Not a valid URL: \(text.debugDescription)")
        }
        guard let scheme = url.scheme?.lowercased() else {
            throw LeoBrowserError(.schemeNotAllowed, "URL must start with http:// or https://: \(trimmed)")
        }
        guard allows(url) else {
            throw LeoBrowserError(.schemeNotAllowed, "Scheme \(scheme): is not allowed; use http, https or about:blank")
        }
        if scheme != "about", url.host?.isEmpty != false {
            throw LeoBrowserError.invalidArgs("URL has no host: \(trimmed)")
        }
        return url
    }

    /// Whether the engine may load `url`: for checking redirects, popups and
    /// links as well as agent-supplied URLs.
    public static func allows(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": true
        case "about": url.absoluteString.lowercased() == "about:blank"
        default: false
        }
    }
}
