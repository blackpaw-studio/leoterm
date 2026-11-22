import Foundation

/// Whether a plugin's source is Blackpaw Studio's own. The owner is fixed in
/// code; there is no setting. Anything that is not clearly Blackpaw's is
/// `.unverified`, so a spoofed host or owner only ever costs a warning.
public enum LeoPluginSourceTrust: Equatable, Sendable {
    case verified
    case unverified
    /// Bundled and dev (local folder) sources carry no trust label.
    case notApplicable

    static let trustedHost = "github.com"
    static let trustedOwner = "blackpaw-studio"

    public static func classify(_ source: LeoPluginSource) -> LeoPluginSourceTrust {
        switch source {
        case .bundled, .dev: return .notApplicable
        case .git(let url, _, _): return classify(gitURL: url)
        }
    }

    private static func classify(gitURL text: String) -> LeoPluginSourceTrust {
        guard case .success(let url) = LeoPluginGitSource.validatedURL(text, allowedSchemes: ["https"]),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.port == nil,
            components.host?.lowercased() == trustedHost,
            let owner = components.path.split(separator: "/").first,
            owner.lowercased() == trustedOwner
        else { return .unverified }
        return .verified
    }
}
