import AppKit
import Darwin
import Foundation

/// What the "Leo can’t start" alert says and what Show in Finder reveals
/// (D-069). The full cache path (`/var/folders/…/C/leo/…instance.lock`)
/// wraps mid-word in an alert, so the text names only `…/<folder>/<file>`;
/// Show in Finder points at the whole thing.
struct LeoCannotStartAlert: Equatable {
    let messageText = "Leo can’t start"
    let informativeText: String
    /// The offending file, or its folder when the file isn't there; nil when
    /// the refusal isn't about a file at all.
    let revealTarget: URL?

    init(refusal: LeoInstanceLockRefusal, fileExists: (String) -> Bool = Self.entryExists) {
        informativeText = refusal.message(showing: Self.abbreviated(refusal.path))
        revealTarget = Self.revealTarget(for: refusal, fileExists: fileExists)
    }

    /// `…/<last folder>/<name>` for a path deeper than that, else the whole
    /// path. Control and invisible formatting characters (a newline, a
    /// right-to-left override) become U+FFFD so a file name can't reshape
    /// the alert text.
    static func abbreviated(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let shown = components.count > 2 ? "…/" + components.suffix(2).joined(separator: "/") : path
        return String(String.UnicodeScalarView(shown.unicodeScalars.map(visible)))
    }

    private static func visible(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.properties.generalCategory {
        case .control, .format: return "\u{FFFD}"
        default: return scalar
        }
    }

    private static func revealTarget(for refusal: LeoInstanceLockRefusal, fileExists: (String) -> Bool) -> URL? {
        switch refusal.error {
        case .invalidBundleIdentifier, .noCacheDirectory:
            return nil
        default:
            guard !fileExists(refusal.path) else { return URL(fileURLWithPath: refusal.path) }
            return URL(fileURLWithPath: (refusal.path as NSString).deletingLastPathComponent, isDirectory: true)
        }
    }

    /// Anything at `path`, a dangling symlink included: that's what's in the way.
    static func entryExists(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0
    }
}

/// Builds and runs the alert: Quit (default, Return) ends it; Show in
/// Finder reveals `revealTarget` through the injected `reveal` and leaves the
/// alert up, since its button targets this object instead of the alert.
@MainActor
final class LeoCannotStartAlertPresenter: NSObject {
    private let content: LeoCannotStartAlert
    private let reveal: ([URL]) -> Void

    init(content: LeoCannotStartAlert, reveal: @escaping ([URL]) -> Void = NSWorkspace.shared.activateFileViewerSelecting) {
        self.content = content
        self.reveal = reveal
    }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = content.messageText
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: "Quit")
        if content.revealTarget != nil {
            let show = alert.addButton(withTitle: "Show in Finder")
            show.target = self
            show.action = #selector(showInFinder(_:))
        }
        return alert
    }

    /// Blocks until Quit; the button's weak target stays alive through `self`.
    func run() {
        _ = withExtendedLifetime(self) { makeAlert().runModal() }
    }

    @objc private func showInFinder(_ sender: Any?) {
        guard let target = content.revealTarget else { return }
        reveal([target])
    }
}
