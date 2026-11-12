import AppKit
import LeoKit

/// Shared look for the plugin renderers: the sidebar's calm greys, system
/// hues only where state matters, SF Symbols throughout.
enum LeoPluginRenderStyle {
    static let gutter: CGFloat = 12
    static let itemRowHeight: CGFloat = 40
    static let compactRowHeight: CGFloat = 28
    static let headerRowHeight: CGFloat = 26

    static func symbol(_ name: String?, pointSize: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        guard let name, !name.isEmpty,
              let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        else { return nil }
        return image.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

    /// Accessory colours reuse the sidebar's tints: neutral stays grey.
    static func ink(for color: LeoPluginAccessoryColor) -> LeoInk {
        switch color {
        case .neutral: .secondary
        case .success: .tint(.green)
        case .warning: .tint(.orange)
        case .failure: .tint(.red)
        case .running: .tint(.blue)
        }
    }

    /// A `Text` run or `Meter` segment's tone: system dynamic colours, so they
    /// follow light and dark mode. The accents run in the order of the status
    /// line the Status plugin mirrors; success/warning/failure reuse the
    /// sidebar's tints.
    static func color(for tone: LeoPluginTone) -> NSColor {
        switch tone {
        case .secondary: .secondaryLabelColor
        case .accent1: .systemPurple
        case .accent2: .systemBlue
        case .accent3: .systemTeal
        case .accent4: .systemOrange
        case .accent5: .systemPink
        case .accent6: .systemIndigo
        case .success: nsColor(for: .tint(.green))
        case .warning: nsColor(for: .tint(.orange))
        case .failure: nsColor(for: .tint(.red))
        }
    }

    static func nsColor(for ink: LeoInk) -> NSColor {
        switch ink {
        case .tint(let tint): tint.nsColor
        case .secondary: .secondaryLabelColor
        case .tertiary: .tertiaryLabelColor
        case .white: .white
        }
    }

    static func label(_ text: String, font: NSFont, color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    static func actionButton(_ entry: LeoPluginActionEntry, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: entry.title, target: target, action: action)
        button.image = symbol(entry.sfSymbol, pointSize: 12)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.tag = entry.index
        return button
    }
}

/// A view that lays its children out top-down, so a stacked slot scrolls from the top.
final class LeoPluginFlippedView: NSView {
    override var isFlipped: Bool { true }
}
