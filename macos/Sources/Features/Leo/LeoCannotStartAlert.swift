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
    /// The refused path, unaltered, for Show in Finder; nil when the refusal
    /// isn't about a file at all.
    private let refusedPath: String?

    init(refusal: LeoInstanceLockRefusal) {
        guard let subject = Self.subject(of: refusal.error) else {
            informativeText = refusal.message
            pathLine = nil
            refusedPath = nil
            return
        }
        informativeText = refusal.message(showing: subject)
        pathLine = PathLine(text: Self.abbreviated(refusal.path), fullPath: Self.neutralised(refusal.path))
        refusedPath = refusal.path
    }

    var canReveal: Bool { refusedPath != nil }

    /// The offending file, or its folder when the file isn't there (asked
    /// each time: the alert tells the user to remove it); nil when the
    /// refusal isn't about a file at all.
    func revealTarget(fileExists: (String) -> Bool = Self.entryExists) -> URL? {
        guard let path = refusedPath else { return nil }
        guard !fileExists(path) else { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
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
    /// path, `neutralised`.
    static func abbreviated(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return neutralised(components.count > 2 ? "…/" + components.suffix(2).joined(separator: "/") : path)
    }

    /// Control, invisible formatting and line/paragraph separator characters
    /// (a newline, U+2028, a right-to-left override) become U+FFFD so a file
    /// name can't reshape the alert text or its tooltip.
    static func neutralised(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map(visible)))
    }

    private static func visible(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return "\u{FFFD}"
        default: return scalar
        }
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
    private let fileExists: (String) -> Bool
    private let reveal: ([URL]) -> Void

    init(
        content: LeoCannotStartAlert,
        fileExists: @escaping (String) -> Bool = LeoCannotStartAlert.entryExists,
        reveal: @escaping ([URL]) -> Void = NSWorkspace.shared.activateFileViewerSelecting
    ) {
        self.content = content
        self.fileExists = fileExists
        self.reveal = reveal
    }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = content.messageText
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: "Quit")
        if content.canReveal {
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
        guard let target = content.revealTarget(fileExists: fileExists) else { return }
        reveal([target])
    }
}
