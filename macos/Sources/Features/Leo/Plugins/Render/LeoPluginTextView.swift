import AppKit
import LeoKit

/// An inline row of styled runs: one line, truncated at the end, with the
/// full text as its tooltip. Tones map to system dynamic colours, so a run
/// follows light and dark mode and a plugin never draws a raw colour.
final class LeoPluginTextView: NSTextField {
    static let fontSize: CGFloat = 11

    /// A summary's text is one truncated line; a body's wraps.
    init(text: LeoPluginNode.Text, wraps: Bool = false) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = wraps ? 0 : 1
        lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(text: text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(text: LeoPluginNode.Text) {
        attributedStringValue = Self.attributedString(for: text)
        toolTip = text.plainText
    }

    static func attributedString(for text: LeoPluginNode.Text) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            result.append(NSAttributedString(string: run.text, attributes: [
                .font: font(for: run),
                .foregroundColor: run.tone.map(LeoPluginRenderStyle.color(for:)) ?? NSColor.labelColor,
            ]))
        }
        return result
    }

    private static func font(for run: LeoPluginNode.Text.Run) -> NSFont {
        let weight: NSFont.Weight = run.weight == .semibold ? .semibold : .regular
        return run.mono
            ? .monospacedSystemFont(ofSize: fontSize, weight: weight)
            : .systemFont(ofSize: fontSize, weight: weight)
    }
}

/// A `Text` in a body: wrapping, inset to the plugin gutter like the other components.
final class LeoPluginTextBodyView: NSView {
    private let label: LeoPluginTextView

    init(text: LeoPluginNode.Text) {
        label = LeoPluginTextView(text: text, wraps: true)
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LeoPluginRenderStyle.gutter),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -LeoPluginRenderStyle.gutter),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(text: LeoPluginNode.Text) { label.update(text: text) }
}
