import AppKit
import LeoKit

/// An inline row of styled runs: one line, truncated at the end, with the
/// full text as its tooltip. Tones map to system dynamic colours, so a run
/// follows light and dark mode and a plugin never draws a raw colour.
final class LeoPluginTextView: NSTextField {
    static let fontSize: CGFloat = 11

    init(text: LeoPluginNode.Text) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
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
