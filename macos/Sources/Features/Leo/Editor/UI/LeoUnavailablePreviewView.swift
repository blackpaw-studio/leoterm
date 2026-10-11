import AppKit

/// "Can’t Preview <Type>" (B-278): a calm, centred state for a binary file,
/// one over the preview limit, or a fetch that failed -- never garbled
/// text. Offers Show in Finder (a local file) or Download (a remote one),
/// and Try Again after a failure.
final class LeoUnavailablePreviewView: NSView {
    enum Action {
        case reveal
        case retry
    }

    var onAction: (Action) -> Void = { _ in }

    init(title: String, message: String?, revealTitle: String) {
        super.init(frame: .zero)
        build(title: title, message: message, revealTitle: revealTitle)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    static func title(typeName: String) -> String { "Can’t Preview \(typeName)" }

    private func build(title: String, message: String?, revealTitle: String) {
        let icon = NSImageView(image: NSImage(systemSymbolName: message == nil ? "doc.questionmark" : "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        var rows: [NSView] = [icon, titleLabel]
        if let message {
            let label = NSTextField(wrappingLabelWithString: message)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.preferredMaxLayoutWidth = 320
            rows.append(label)
        }
        let buttons = NSStackView(views: [button(revealTitle, .reveal)] + (message == nil ? [] : [button("Try Again", .retry)]))
        buttons.orientation = .horizontal
        buttons.spacing = 8
        rows.append(buttons)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, message].compactMap { $0 }.joined(separator: ". "))
    }

    private func button(_ title: String, _ action: Action) -> NSButton {
        let button = NSButton(title: title, target: self, action: action == .reveal ? #selector(reveal(_:)) : #selector(retry(_:)))
        button.bezelStyle = .push
        button.controlSize = .regular
        return button
    }

    @objc private func reveal(_ sender: Any?) { onAction(.reveal) }
    @objc private func retry(_ sender: Any?) { onAction(.retry) }
}

/// A preview's file on its way: a progress bar once its size is known.
final class LeoLoadingPreviewView: NSView {
    private let progress = NSProgressIndicator()

    init(fraction: Double?) {
        super.init(frame: .zero)
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        let label = NSTextField(labelWithString: "Loading…")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [progress, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 180),
        ])
        update(fraction: fraction)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func update(fraction: Double?) {
        progress.isIndeterminate = fraction == nil
        if let fraction {
            progress.stopAnimation(nil)
            progress.doubleValue = fraction
        } else {
            progress.startAnimation(nil)
        }
        setAccessibilityLabel(fraction.map { "Loading, \(Int($0 * 100)) percent" } ?? "Loading")
    }
}
