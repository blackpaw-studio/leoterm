import SwiftUI
import LeoKit

/// One rule in the Appearance pane: when field op value, then a color and
/// an emoji, the number of agents it matches, and its problem inline.
struct LeoAppearanceRuleRow: View {
    let number: Int
    let rule: LeoAppearanceRule
    let problem: String?
    let matchCount: Int
    let update: (LeoAppearanceRule) -> Void
    let delete: () -> Void

    /// The number column; the "then" line and the problem indent past it.
    private static let numberWidth: CGFloat = 18
    private static let spacing: CGFloat = 6

    // Two lines, "when" over "then": one line overflows the rules column
    // beside the preview at the window's default width.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Self.spacing) {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Self.numberWidth, alignment: .trailing)
                fieldPicker
                opPicker
                TextField("Value", text: binding(\.when.value) { rule, value in
                    LeoAppearanceRule(field: rule.when.field, op: rule.when.op, value: value, color: rule.color, emoji: rule.emoji)
                })
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, maxWidth: .infinity)
            }
            HStack(spacing: Self.spacing) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                colorMenu
                TextField("Emoji", text: binding(\.emojiText) { rule, emoji in
                    LeoAppearanceRule(field: rule.when.field, op: rule.when.op, value: rule.when.value, color: rule.color, emoji: emoji)
                })
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .help("An emoji; Edit ▸ Emoji & Symbols opens the picker.")
                Spacer(minLength: 8)
                Text(matchCount == 1 ? "1 agent" : "\(matchCount) agents")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: delete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Delete Rule")
                    .accessibilityLabel("Delete Rule \(number)")
            }
            .padding(.leading, Self.numberWidth + Self.spacing)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, Self.numberWidth + Self.spacing)
            }
        }
        .padding(.vertical, 4)
    }

    private var fieldPicker: some View {
        Picker("Field", selection: binding(\.when.field) { rule, field in
            LeoAppearanceRule(field: field, op: rule.when.op, value: rule.when.value, color: rule.color, emoji: rule.emoji)
        }) {
            ForEach(LeoAppearanceRule.Field.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            if rule.field == nil { Text(rule.when.field).tag(rule.when.field) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var opPicker: some View {
        Picker("Comparison", selection: binding(\.when.op) { rule, op in
            LeoAppearanceRule(field: rule.when.field, op: op, value: rule.when.value, color: rule.color, emoji: rule.emoji)
        }) {
            ForEach(LeoAppearanceRule.Op.allCases, id: \.rawValue) { Text($0.phrase).tag($0.rawValue) }
            if rule.op == nil { Text(rule.when.op).tag(rule.when.op) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var colorMenu: some View {
        Menu {
            Button("None") { setColor(nil) }
            Divider()
            ForEach(LeoAppearanceColor.allCases, id: \.self) { color in
                Button { setColor(color.rawValue) } label: {
                    Label { Text(color.displayName) } icon: { Image(nsImage: LeoAppearanceSwatchImage.make(color)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(rule.paletteColor?.swiftUIColor ?? Color.secondary.opacity(0.2)).frame(width: 10, height: 10)
                Text(rule.paletteColor?.displayName ?? rule.color ?? "No Color")
            }
        }
        .fixedSize()
        .accessibilityLabel("Color")
    }

    private func setColor(_ color: String?) {
        update(LeoAppearanceRule(field: rule.when.field, op: rule.when.op, value: rule.when.value, color: color, emoji: rule.emoji))
    }

    private func binding(_ read: KeyPath<LeoAppearanceRule, String>, _ write: @escaping (LeoAppearanceRule, String) -> LeoAppearanceRule) -> Binding<String> {
        Binding(get: { rule[keyPath: read] }, set: { update(write(rule, $0)) })
    }
}

private extension LeoAppearanceRule {
    var emojiText: String { emoji ?? "" }
}

/// A menu item can't draw a SwiftUI shape: a small filled circle image.
enum LeoAppearanceSwatchImage {
    static func make(_ color: LeoAppearanceColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.accessibilityDescription = color.displayName
        return image
    }
}
