import LeoKit
import SwiftUI

/// The loaded Appearance pane: the rules list with its bottom bar and Save and
/// Revert, beside the live preview.
struct LeoAppearanceEditor: View {
    @ObservedObject var model: LeoAppearanceSettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rules
            Divider()
            preview.frame(width: 240)
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance rules").font(.headline)
                Text("The first rule that matches sets an agent’s color or emoji, unless the agent has its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(LeoSettingsMetrics.groupPadding)
            List(selection: $model.selection) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    LeoAppearanceRuleRow(
                        number: index + 1, rule: row.rule, problem: model.problem(at: index), matchCount: model.matchCount(at: index),
                        update: { model.update(row.id, $0) }
                    )
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                if model.rows.isEmpty {
                    Text("No rules. Agents show only the emoji and color set on them.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            LeoListBottomBar(canRemove: model.selection != nil, remove: model.deleteSelected) {
                LeoBarAddButton(label: "Add Rule", action: model.add)
            }
            footer.padding(LeoSettingsMetrics.groupPadding)
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(LeoSettingsStatus.failure.color).lineLimit(2)
            }
            Spacer()
            Button("Revert") { model.revert() }.disabled(!model.isDirty || model.isSaving)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview").font(.headline).padding(LeoSettingsMetrics.groupPadding)
            List(model.preview) { entry in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: LeoAgentRowMetrics.emojiSpacing) {
                            if let emoji = entry.appearance?.emoji { Text(emoji).font(.callout) }
                            Text(entry.name).lineLimit(1)
                        }
                        Text(entry.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(entry.appearance?.color?.swiftUIColor ?? .clear)
                        .frame(width: LeoAgentRowMetrics.colorBarWidth, height: 28)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
        }
    }
}
