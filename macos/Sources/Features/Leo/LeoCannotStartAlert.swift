import AppKit
import Darwin
import Foundation

/// What the "Leo can’t start" alert says and what Show in Finder reveals
/// (D-069). A cache path (`/var/folders/…/C/leo/…instance.lock`) wraps and
/// hyphenates mid-word in an alert's sentence, so the sentence names the
/// file by role and the path gets its own line, `…/<folder>/<file>`, below.
struct LeoCannotStartAlert: Equatable {
    /// The path under the sentence: `text` shown, `fullPath` as its tooltip.
    struct PathLine: Equatable {
        let text: String
        let fullPath: String
    }

    let messageText = "Leo can’t start"
    let informativeText: String
    /// Nil when the refusal isn't about a file at all.
    let pathLine: PathLine?
    /// The offending file, or its folder when the file isn't there; nil when
    /// the refusal isn't about a file at all.
    let revealTarget: URL?

    init(refusal: LeoInstanceLockRefusal, fileExists: (String) -> Bool = Self.entryExists) {
        guard let subject = Self.subject(of: refusal.error) else {
            informativeText = refusal.message
            pathLine = nil
            revealTarget = nil
            return
        }
        informativeText = refusal.message(showing: subject)
        pathLine = PathLine(text: Self.abbreviated(refusal.path), fullPath: refusal.path)
        revealTarget = Self.revealTarget(for: refusal.path, fileExists: fileExists)
    }

    /// What the refused path is, in words; nil when there's no file.
    private static func subject(of error: LeoInstanceLockError) -> String? {
        switch error {
        case .invalidBundleIdentifier, .noCacheDirectory: return nil
        case .directory: return "Leo’s lock folder"
        case .notARegularFile, .notOwned, .linked, .system: return "Leo’s instance lock"
        }
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

    private static func revealTarget(for path: String, fileExists: (String) -> Bool) -> URL {
        guard !fileExists(path) else { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
    }

    /// Anything at `path`, a dangling symlink included: that's what's in the way.
    static func entryExists(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0
    }
}

/// Builds and runs the alert: the path line as its accessory view; Quit
/// (default, Return) ends it; Show in Finder reveals `revealTarget` through
/// the injected `reveal` and leaves the alert up, since its button targets
/// this object instead of the alert.
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
        if let pathLine = content.pathLine {
            alert.accessoryView = Self.label(for: pathLine, width: Self.textWidth(of: alert))
            alert.layout()
        }
        return alert
    }

    /// One selectable line that truncates in the middle instead of wrapping.
    private static func label(for pathLine: LeoCannotStartAlert.PathLine, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: pathLine.text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isSelectable = true
        label.toolTip = pathLine.fullPath
        label.frame = NSRect(x: 0, y: 0, width: width, height: label.intrinsicContentSize.height)
        return label
    }

    /// The width of the alert's own informative text once laid out, so the
    /// path line never widens the alert; the content width if it isn't found.
    private static func textWidth(of alert: NSAlert) -> CGFloat {
        alert.layout()
        let content = alert.window.contentView
        let informative = content.flatMap { findLabel(in: $0, showing: alert.informativeText) }
        return informative?.frame.width ?? max((content?.bounds.width ?? 0) - 2 * fallbackMargin, minimumWidth)
    }

    private static let fallbackMargin: CGFloat = 16
    private static let minimumWidth: CGFloat = 200

    private static func findLabel(in view: NSView, showing text: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text { return field }
        return view.subviews.lazy.compactMap { findLabel(in: $0, showing: text) }.first
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
