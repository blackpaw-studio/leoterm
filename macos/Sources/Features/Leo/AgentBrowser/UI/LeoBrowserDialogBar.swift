import AppKit
import LeoKit

/// The bar under the permission bar while the active tab's page waits on a
/// JavaScript dialog (B-412): its alert, confirm, prompt or "Leave this
/// page?". Inline, never a sheet or WebKit's own panel: an agent's click can
/// open one, and it must never freeze the window the terminals share. The
/// agent may answer first; then the bar says so for a moment.
///
/// No button has a key equivalent, so no typing in the page -- the user's
/// or an agent's -- can answer, and Return never accepts a confirm. Only in
/// a prompt's own field does Return mean OK (and Escape Cancel): the user
/// typed the answer there.
final class LeoBrowserDialogBar: NSView, NSTextFieldDelegate {
    enum Content: Equatable {
        case dialog(LeoBrowserDialogPrompt)
        /// The agent answered the dialog the bar showed: "alfred answered: OK".
        case handled(String)
    }

    /// OK or Leave Page (`true`), Cancel or Stay on Page; a prompt's text with OK.
    var onAnswer: (_ accept: Bool, _ text: String?) -> Void = { _, _ in }
    /// Says each new dialog, and the agent's answer, once for VoiceOver,
    /// without moving focus.
    var onAnnounce: (String) -> Void = { _ in }

    /// At this width and above the buttons sit beside the text; below it
    /// they go under it, as the permission bar does.
    static let wideWidth: CGFloat = 640
    static let messageLines = 4
    private static let fieldWidth: CGFloat = 320
    private static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
    private static let spacing: CGFloat = 8

    private let icon = NSImageView()
    private let textColumn = NSStackView()
    private let textRow = NSStackView()
    private let content = NSStackView()
    private let buttons = NSStackView()
    private var textFillsWidth: NSLayoutConstraint?
    private var isWide: Bool?
    let headerLabel = NSTextField(labelWithString: "")
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let textField = NSTextField(string: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton()
    let okButton = NSButton()
    /// What the bar shows; nil while hidden.
    private(set) var current: Content?
    private var announced: Content?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show(_ content: Content?) {
        guard content != current else { return }
        let previous = current
        current = content
        isHidden = content == nil
        switch content {
        case .dialog(let prompt):
            display(prompt, isNew: previous.flatMap(Self.dialogID) != prompt.id)
        case .handled(let line):
            showHandled(line)
        case nil:
            return
        }
        guard let content, announced != content else { return }
        announced = content
        onAnnounce(accessibilityLabel() ?? "")
    }

    /// `text` ending as a sentence, for VoiceOver.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.last.map { ".?!…".contains($0) } == true ? trimmed : trimmed + "."
    }

    private static func dialogID(_ content: Content) -> Int? {
        if case .dialog(let prompt) = content { return prompt.id }
        return nil
    }

    private func display(_ prompt: LeoBrowserDialogPrompt, isNew: Bool) {
        headerLabel.stringValue = prompt.header
        messageLabel.stringValue = prompt.message
        messageLabel.toolTip = prompt.message
        detailLabel.stringValue = prompt.detail
        icon.image = NSImage(systemSymbolName: prompt.kind == .leave ? "rectangle.portrait.and.arrow.right" : "exclamationmark.bubble", accessibilityDescription: nil)
        okButton.title = LeoBrowserDialogText.buttonTitle(prompt.kind, accepted: true)
        cancelButton.title = LeoBrowserDialogText.buttonTitle(prompt.kind, accepted: false)
        cancelButton.isHidden = prompt.kind == .alert
        textField.isHidden = prompt.kind != .prompt
        if isNew { textField.stringValue = prompt.dialog.defaultText ?? "" }
        textField.setAccessibilityLabel(prompt.message)
        [headerLabel, detailLabel, buttons].forEach { $0.isHidden = false }
        setAccessibilityLabel("\(prompt.header) \(Self.sentence(prompt.message)) \(prompt.detail)")
        needsLayout = true
    }

    private func showHandled(_ line: String) {
        messageLabel.stringValue = line
        messageLabel.toolTip = nil
        icon.image = NSImage(systemSymbolName: "checkmark.bubble", accessibilityDescription: nil)
        [headerLabel, detailLabel, textField, buttons].forEach { $0.isHidden = true }
        setAccessibilityLabel(line)
        needsLayout = true
    }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true

        icon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let small = NSFont.smallSystemFontSize
        for (label, font, color, lines) in [
            (headerLabel, NSFont.systemFont(ofSize: small), NSColor.secondaryLabelColor, 1),
            (messageLabel, NSFont.systemFont(ofSize: small, weight: .semibold), NSColor.labelColor, Self.messageLines),
            (detailLabel, NSFont.systemFont(ofSize: small), NSColor.secondaryLabelColor, 2),
        ] {
            label.font = font
            label.textColor = color
            label.maximumNumberOfLines = lines
            label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        textField.font = .systemFont(ofSize: small)
        textField.controlSize = .small
        textField.delegate = self
        textField.isHidden = true
        // As wide as a short answer needs; the column narrows it in a narrow pane.
        let fieldWidth = textField.widthAnchor.constraint(equalToConstant: Self.fieldWidth)
        fieldWidth.priority = .defaultHigh
        fieldWidth.isActive = true
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(cancelButton, action: #selector(cancel(_:)))
        configure(okButton, action: #selector(accept(_:)))
        buttons.setViews([cancelButton, okButton], in: .leading)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        textColumn.setViews([headerLabel, messageLabel, textField, detailLabel], in: .leading)
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2

        textRow.setViews([icon, textColumn], in: .leading)
        textRow.orientation = .horizontal
        textRow.alignment = .top
        textRow.spacing = Self.spacing
        textRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        content.setViews([textRow, buttons], in: .leading)
        content.spacing = Self.spacing
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Insets as constraints, not `edgeInsets`: a vertical stack aligned
        // .trailing ignores the right inset (B-410).
        textFillsWidth = textRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom),
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
        let used = Self.insets.left + Self.insets.right + icon.fittingSize.width + Self.spacing
        let beside = isWide == true && !buttons.isHidden ? buttons.fittingSize.width + Self.spacing : 0
        let width = max(bounds.width - used - beside, 0)
        guard abs(messageLabel.preferredMaxLayoutWidth - width) > 0.5 else { return }
        for label in [headerLabel, messageLabel, detailLabel] {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    private func configure(_ button: NSButton, action: Selector) {
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

    @objc private func accept(_ sender: Any?) { answer(true) }
    @objc private func cancel(_ sender: Any?) { answer(false) }

    private func answer(_ accept: Bool) {
        guard case .dialog(let prompt) = current else { return }
        onAnswer(accept, accept && prompt.kind == .prompt ? textField.stringValue : nil)
    }

    // MARK: - NSTextFieldDelegate

    /// Return in the prompt's field is OK, Escape is Cancel.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === textField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            answer(true)
        case #selector(NSResponder.cancelOperation(_:)):
            answer(false)
        default:
            return false
        }
        return true
    }
}
