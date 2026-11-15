import Foundation

/// The `Version/x Safari/605.1.15` tail of the agent browser's user agent.
/// A bare `WKWebView` sends no such tail, and sites that gate on the Safari
/// version (chase.com sends it to its "unsupported browser" page) turn it
/// away. The version is the installed Safari's, as the system browser sends.
enum LeoBrowserUserAgent {
    /// The version claimed when Safari is not installed: the oldest Safari
    /// that runs on the oldest macOS Leo supports.
    static let fallbackVersion = "17.0"
    static let safariBuild = "605.1.15"
    static let safariBundlePaths = [
        "/Applications/Safari.app",
        "/System/Cryptexes/App/System/Applications/Safari.app",
    ]

    /// `Version/<major.minor> Safari/605.1.15`, for
    /// `WKWebViewConfiguration.applicationNameForUserAgent`.
    static func applicationName(
        safariVersion: () -> String? = { installedSafariVersion() }
    ) -> String {
        let version = safariVersion().flatMap(majorMinor) ?? fallbackVersion
        return "Version/\(version) Safari/\(safariBuild)"
    }

    /// The installed Safari's short version string, such as "26.1".
    static func installedSafariVersion(
        bundlePaths: [String] = safariBundlePaths, bundle: (String) -> Bundle? = { Bundle(path: $0) }
    ) -> String? {
        bundlePaths.lazy
            .compactMap(bundle)
            .compactMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            .first
    }

    /// "26.1.2 (build)" -> "26.1"; "26" -> "26.0"; nil unless it starts numeric.
    static func majorMinor(_ version: String) -> String? {
        let parts = version.split(separator: " ")[0].split(separator: ".").prefix(2)
        guard let major = parts.first, major.allSatisfy(\.isNumber) else { return nil }
        let minor = parts.dropFirst().first.map(String.init).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil } ?? "0"
        return "\(major).\(minor)"
    }
}
