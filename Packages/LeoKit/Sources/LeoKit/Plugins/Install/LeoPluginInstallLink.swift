import Foundation

/// A `leo://plugin/install?url=<https git URL>[&ref=<ref>]` link, parsed
/// strictly. Parsing never installs anything: the app only fills the
/// Install-from-URL sheet with the result and the normal review follows.
public struct LeoPluginInstallLink: Equatable, Sendable {
    public let url: URL
    public let ref: String?

    /// `leo-debug` is the scheme a debug build registers, so a dev build never
    /// takes links from the installed app. Both parse everywhere; the OS only
    /// routes the scheme a build registered.
    public static let schemes: Set<String> = ["leo", "leo-debug"]

    static let host = "plugin"
    static let path = "/install"
    static let allowedKeys: Set<String> = ["url", "ref"]

    public static func parse(_ link: URL) -> Result<LeoPluginInstallLink, LeoPluginInstallLinkError> {
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), schemes.contains(scheme)
        else { return .failure(.wrongScheme) }
        guard components.host?.lowercased() == host, components.path == path,
            components.user == nil, components.password == nil, components.port == nil, components.fragment == nil
        else { return .failure(.wrongTarget) }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowedKeys.contains(item.name) else { return .failure(.unknownKey(item.name)) }
            guard values[item.name] == nil else { return .failure(.duplicateKey(item.name)) }
            values[item.name] = item.value ?? ""
        }

        guard let rawURL = values["url"] else { return .failure(.missingURL) }
        let url: URL
        switch LeoPluginGitSource.validatedURL(rawURL, allowedSchemes: ["https"]) {
        case .success(let valid): url = valid
        case .failure(.invalidURL(let reason)): return .failure(.invalidURL(reason))
        case .failure(let other): return .failure(.invalidURL(other.localizedDescription))
        }

        guard let rawRef = values["ref"] else { return .success(LeoPluginInstallLink(url: url, ref: nil)) }
        guard !rawRef.isEmpty, rawRef == rawRef.trimmingCharacters(in: .whitespacesAndNewlines),
            case .success(let ref) = LeoPluginGitSource.validatedRef(rawRef)
        else { return .failure(.invalidRef(rawRef)) }
        return .success(LeoPluginInstallLink(url: url, ref: ref))
    }
}

public enum LeoPluginInstallLinkError: Error, Equatable, LocalizedError, Sendable {
    case wrongScheme
    /// The host, path, port, credentials or fragment is not `leo://plugin/install`.
    case wrongTarget
    case unknownKey(String)
    case duplicateKey(String)
    case missingURL
    case invalidURL(String)
    case invalidRef(String)

    public var errorDescription: String? {
        switch self {
        case .wrongScheme: "This isn't a Leo link."
        case .wrongTarget: "Leo only understands plugin install links (leo://plugin/install)."
        case .unknownKey(let key): "The link has an option Leo doesn't understand: '\(key)'."
        case .duplicateKey(let key): "The link gives '\(key)' more than once."
        case .missingURL: "The link doesn't say which plugin to install."
        case .invalidURL(let reason): "The link's plugin address can't be used: \(reason)."
        case .invalidRef(let ref): "The link's branch or tag '\(ref)' is not a usable name."
        }
    }
}
