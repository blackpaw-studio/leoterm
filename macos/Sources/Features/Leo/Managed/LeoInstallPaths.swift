import Foundation

/// Where the app keeps its managed-daemon state (D11). Everything under
/// `~/.leo/app` is space-free so leo can persist it in plists and hooks
/// without quoting. Pure: tests pass a scratch `home`; production uses
/// `FileManager.homeDirectoryForCurrentUser`, which honours
/// `CFFIXED_USER_HOME`.
struct LeoInstallPaths: Equatable, Sendable {
    static let markerFileName = "managed.json"
    static let backupFileName = "leo.pre-leoapp"

    let home: URL
    let bundleURL: URL

    init(home: URL, bundleURL: URL) {
        self.home = home.standardizedFileURL
        self.bundleURL = bundleURL.standardizedFileURL
    }

    static func live(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) -> Self {
        Self(home: home, bundleURL: bundle.bundleURL)
    }

    // MARK: leo's own state

    var stateDirectory: URL { home.appendingPathComponent(".leo/state", isDirectory: true) }
    var markerURL: URL { stateDirectory.appendingPathComponent(Self.markerFileName) }

    // MARK: app-owned, space-free root

    var appRoot: URL { home.appendingPathComponent(".leo/app", isDirectory: true) }
    var binDirectory: URL { appRoot.appendingPathComponent("bin", isDirectory: true) }
    /// The marker's `self_path`: a symlink to the bundled helper, persisted unresolved.
    var selfLinkURL: URL { binDirectory.appendingPathComponent("leo") }
    var tmuxRoot: URL { appRoot.appendingPathComponent("tmux", isDirectory: true) }

    /// `~/.leo/app/tmux/<version>/tmux`, or nil when `version` could escape the
    /// tmux root (it comes from `tmux -V` output).
    func tmuxURL(version: String) -> URL? {
        guard Self.isSafeVersionComponent(version) else { return nil }
        return tmuxRoot.appendingPathComponent(version, isDirectory: true).appendingPathComponent("tmux")
    }

    // MARK: inside the bundle

    var helpersDirectory: URL { bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
    var bundledLeo: URL { helpersDirectory.appendingPathComponent("leo") }
    var bundledTmux: URL { helpersDirectory.appendingPathComponent("tmux") }
    var bundledTerminfo: URL { bundleURL.appendingPathComponent("Contents/Resources/terminfo", isDirectory: true) }

    // MARK: the user's own PATH

    var localBinDirectory: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    var localBinLeo: URL { localBinDirectory.appendingPathComponent("leo") }
    var localBinLeoBackup: URL { localBinDirectory.appendingPathComponent(Self.backupFileName) }

    private static func isSafeVersionComponent(_ version: String) -> Bool {
        guard let first = version.first, first != "." else { return false }
        return version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}
