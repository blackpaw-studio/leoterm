import AppKit

/// What the pane's inline banner says, most important first: a quit
/// waiting on the editor, a close waiting on it, a conflict with the disk,
/// then a failed save or reload, then a read-only notice.
struct LeoEditorBanner: Equatable {
    enum Action: Equatable {
        case quitAnyway
        case reload
        case keepMine
        case dismissError
    }

    let symbol: String
    let message: String
    let actions: [Action]
    /// Whether its buttons can be used now.
    var isEnabled = true

    /// nil when there is nothing to say. `isQuitWaiting`: a pending quit
    /// is waiting on the document's disk or connection (a save or read
    /// that hasn't come back), and it can be left from here.
    /// `canLeave`: whether its Quit Anyway can be used now (no offer to
    /// leave is already showing). `isWaitingToClose`: a close is waiting
    /// on the document's disk or connection (or on work queued before it).
    @MainActor static func current(for document: LeoEditorDocument?, isQuitWaiting: Bool = false, canLeave: Bool = true, isWaitingToClose: Bool = false) -> LeoEditorBanner? {
        guard let document else { return nil }
        let name = "“\(LeoSFTPServerText.isolated(document.displayName))”"
        if isQuitWaiting {
            return LeoEditorBanner(
                symbol: "hourglass",
                message: "Quitting is waiting for \(document.fileID.host.displayName) to finish with \(name).",
                actions: [.quitAnyway],
                isEnabled: canLeave
            )
        }
        if isWaitingToClose {
            return LeoEditorBanner(symbol: "hourglass", message: "Closing \(name)…", actions: [])
        }
        switch document.diskState {
        case .changed:
            return LeoEditorBanner(
                symbol: "exclamationmark.triangle",
                message: "\(name) changed on disk. Reload to see it, or keep your version and save over it.",
                actions: [.reload, .keepMine]
            )
        case .deleted:
            return LeoEditorBanner(
                symbol: "trash",
                message: "\(name) was deleted on disk. Keep your version to save it again.",
                actions: [.keepMine]
            )
        case .inSync:
            break
        }
        if let error = document.errorMessage {
            return LeoEditorBanner(symbol: "xmark.octagon", message: error, actions: [.dismissError])
        }
        if let reason = document.readOnlyReason {
            return LeoEditorBanner(symbol: "lock", message: reason.notice, actions: [])
        }
        return nil
    }
}

extension LeoEditorBanner.Action {
    var title: String {
        switch self {
        case .quitAnyway: "Quit Anyway…"
        case .reload: "Reload"
        case .keepMine: "Keep Mine"
        case .dismissError: "OK"
        }
    }
}

/// A calm inline banner: an icon, one line of text, and small buttons.
final class LeoEditorBannerView: NSView {
    var onAction: (LeoEditorBanner.Action) -> Void = { _ in }

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private(set) var banner: LeoEditorBanner?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show(_ banner: LeoEditorBanner?) {
        guard banner != self.banner else { return }
        self.banner = banner
        isHidden = banner == nil
        guard let banner else { return }
        icon.image = NSImage(systemSymbolName: banner.symbol, accessibilityDescription: nil)
        label.stringValue = banner.message
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in banner.actions {
            let button = NSButton(title: action.title, target: self, action: #selector(performAction(_:)))
            button.controlSize = .small
            button.bezelStyle = .push
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = banner.actions.firstIndex(of: action) ?? 0
            button.isEnabled = banner.isEnabled
            buttons.addArrangedSubview(button)
        }
        setAccessibilityLabel(banner.message)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true

        icon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label, buttons])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Drawn rather than layer-backed so the dynamic colour follows the
    /// appearance. Only within its bounds: views don't clip to them (macOS
    /// 14+), so `dirtyRect` can reach past it -- filling that painted over
    /// the header above (B-045).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func performAction(_ sender: NSButton) {
        guard let actions = banner?.actions, actions.indices.contains(sender.tag) else { return }
        onAction(actions[sender.tag])
    }
}
