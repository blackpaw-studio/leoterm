import Foundation

/// Which link schemes a rendered document may make tappable. Everything
/// else (javascript:, file:, tel:, relative paths) stays plain text.
public enum LeoMarkdownLinkPolicy {
    public static let schemes: Set<String> = ["http", "https", "mailto"]

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }
}
