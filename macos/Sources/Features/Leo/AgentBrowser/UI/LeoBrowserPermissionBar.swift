import AppKit
import LeoKit

/// The bar under the browser toolbar while the active tab's page waits on
/// the user to allow its camera, microphone or location (B-410). Inline,
/// never a sheet or WebKit's own prompt: the request can come from an
/// agent's click, and must never freeze the window the terminals share.
///
/// Neither button has a key equivalent, so no typing in the page -- the
/// user's or an agent's -- can answer it: only a click (or VoiceOver press).
final class LeoBrowserPermissionBar: NSView {
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    /// Says a new prompt once, for VoiceOver, without moving focus.
    var onAnnounce: (String) -> Void = { _ in }

    /// At this width and above the buttons sit beside the text; below it
    /// they go under it, as the handoff banner does.
    static let wideWidth: CGFloat = 640
    private static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
    private static let spacing: CGFloat = 8

    private let icon = NSImageView()
    private let textColumn = NSStackView()
    private let textRow = NSStackView()
    private let content = NSStackView()
    private let buttons = NSStackView()
    private var textFillsWidth: NSLayoutConstraint?
    private var isWide: Bool?
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: LeoBrowserPermissionPrompt.detail)
    let denyButton = NSButton()
    let allowButton = NSButton()
    private(set) var prompt: LeoBrowserPermissionPrompt?
    private var announcedID: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show(_ prompt: LeoBrowserPermissionPrompt?) {
        guard prompt != self.prompt else { return }
        self.prompt = prompt
        isHidden = prompt == nil
        guard let prompt else { return }
        messageLabel.stringValue = prompt.message
        icon.image = NSImage(systemSymbolName: Self.symbol(for: prompt.request.kind), accessibilityDescription: nil)
        setAccessibilityLabel("\(prompt.message). \(LeoBrowserPermissionPrompt.detail)")
        guard announcedID != prompt.id else { return }
        announcedID = prompt.id
        onAnnounce("\(prompt.message). \(LeoBrowserPermissionPrompt.detail)")
    }

    static func symbol(for kind: LeoBrowserPermissionKind) -> String {
        switch kind {
        case .camera, .cameraAndMicrophone: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        }
    }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true

        icon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        for (label, font, color) in [
            (messageLabel, NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), NSColor.labelColor),
            (detailLabel, NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), NSColor.secondaryLabelColor),
        ] {
            label.font = font
            label.textColor = color
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        configure(denyButton, title: "Don’t Allow", action: #selector(deny(_:)))
        configure(allowButton, title: "Allow", action: #selector(allow(_:)))
        denyButton.toolTip = "Deny this page’s request until the tab closes"
        allowButton.toolTip = "Allow this page’s request until the tab closes"

        buttons.setViews([denyButton, allowButton], in: .leading)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        textColumn.setViews([messageLabel, detailLabel], in: .leading)
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1

        textRow.setViews([icon, textColumn], in: .leading)
        textRow.orientation = .horizontal
        textRow.alignment = .top
        textRow.spacing = Self.spacing

        content.setViews([textRow, buttons], in: .leading)
        content.spacing = Self.spacing
        content.edgeInsets = Self.insets
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        textFillsWidth = textRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -(Self.insets.left + Self.insets.right))
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        arrange(wide: true)
    }

    /// Wide: text and buttons on one row. Narrow: the buttons, trailing,
    /// under the text.
    private func arrange(wide: Bool) {
        guard wide != isWide else { return }
        isWide = wide
        content.orientation = wide ? .horizontal : .vertical
        content.alignment = wide ? .centerY : .trailing
        textFillsWidth?.isActive = !wide
    }

    /// A wrapping label only knows its height once told its width.
    override func layout() {
        super.layout()
        arrange(wide: bounds.width >= Self.wideWidth)
        let iconWidth = icon.fittingSize.width
        let used = Self.insets.left + Self.insets.right + iconWidth + Self.spacing
        let beside = isWide == true ? buttons.fittingSize.width + Self.spacing : 0
        let width = max(bounds.width - used - beside, 0)
        guard abs(messageLabel.preferredMaxLayoutWidth - width) > 0.5 else { return }
        for label in [messageLabel, detailLabel] {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.controlSize = .small
        button.bezelStyle = .push
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.keyEquivalent = ""
    }

    /// Drawn rather than layer-backed so the tint follows the appearance;
    /// within the bounds only (views don't clip on macOS 14+).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func allow(_ sender: Any?) { onAllow() }
    @objc private func deny(_ sender: Any?) { onDeny() }
}
