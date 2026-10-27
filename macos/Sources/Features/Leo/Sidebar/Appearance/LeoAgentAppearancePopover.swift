import SwiftUI
import LeoKit

/// Appearance… on an agent row: emoji search and grid, the palette plus
/// None, where each value comes from, Reset to rules and Edit rules….
/// Each pick is written at once; there is no Save.
struct LeoAgentAppearancePopover: View {
    let row: LeoAgentRow
    let client: (any LeoAppearanceAPI)?
    let editRules: () -> Void

    var body: some View {
        if let client {
            LeoAgentAppearanceEditor(row: row, client: client, editRules: editRules)
        } else {
            Text("\(SpawnMachineOption.title(for: row.host)) isn't connected.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }
}

private struct LeoAgentAppearanceEditor: View {
    static let width: CGFloat = 320
    /// The popover's padding on all four sides; the sections share the
    /// `width - 2 × inset` column inside it.
    static let inset: CGFloat = 14
    static let gridColumns = Array(repeating: GridItem(.flexible(minimum: 24), spacing: 2), count: 8)

    let row: LeoAgentRow
    let editRules: () -> Void
    @StateObject private var model: LeoAgentAppearanceModel

    init(row: LeoAgentRow, client: any LeoAppearanceAPI, editRules: @escaping () -> Void) {
        self.row = row
        self.editRules = editRules
        _model = StateObject(wrappedValue: LeoAgentAppearanceModel(
            agent: row.name, appearance: row.appearance, client: client, recents: LeoEmojiRecents(defaults: .standard)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField("Search emoji", text: $model.query)
                .textFieldStyle(.roundedBorder)
            emojiGrid
            colorRow
            sourceBox
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Reset to Rules") { Task { await model.resetToRules() } }
                    .disabled(!model.canReset || model.isSaving)
                Spacer()
                Button("Edit Rules…", action: editRules)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        // Fix the column, then pad it: a row wider than the column can no
        // longer widen the content past the popover and shift every
        // section off its inset.
        .frame(width: Self.width - 2 * Self.inset)
        .padding(Self.inset)
        .task { await model.load() }
        .onChange(of: row.appearance) { model.receive($0) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.appearance?.color.map { $0.swiftUIColor.opacity(0.22) } ?? Color.secondary.opacity(0.12))
                if let emoji = model.appearance?.emoji {
                    Text(emoji).font(.title2)
                } else {
                    Image(systemName: "face.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.headline).lineLimit(1)
                Text([SpawnMachineOption.title(for: row.host), row.template].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var emojiGrid: some View {
        let isSearching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let results = isSearching ? model.results : []
        return ScrollView {
            if isSearching, results.isEmpty {
                Text("No Emoji Found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if isSearching {
                    cells(results)
                } else {
                    Section { noEmojiCell; cells(model.frequent) } header: { sectionTitle("Frequently Used") }
                    ForEach(model.groups) { group in
                        Section { cells(group.entries) } header: { sectionTitle(group.name) }
                    }
                }
            }
        }
        .frame(height: 196)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .background(.regularMaterial)
    }

    private func cells(_ entries: [LeoEmojiEntry]) -> some View {
        ForEach(entries) { entry in
            let isCurrent = entry.emoji == model.appearance?.emoji
            Button {
                Task { isCurrent ? await model.clearEmoji() : await model.pickEmoji(entry.emoji) }
            } label: {
                Text(entry.emoji)
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(isCurrent ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.name)
            .accessibilityLabel(entry.name)
            .disabled(model.isSaving)
        }
    }

    /// "No emoji": the grid's first cell, like None among the colors.
    private var noEmojiCell: some View {
        let isCurrent = model.appearance?.emoji == nil
        return Button { Task { await model.clearEmoji() } } label: {
            Image(systemName: "nosign")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isCurrent ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("No Emoji")
        .accessibilityLabel("No Emoji")
        .disabled(isCurrent || model.isSaving)
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Color").font(.caption.weight(.semibold))
                Spacer()
                // None picked, yet a rule's color shows: say whose.
                if model.colorPick == nil, model.appearance?.color != nil {
                    Text(model.noneColorLabel).font(.caption).lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            // None plus ten swatches are 11 × 24 wide, so they fit the
            // 292 pt column with the slack spread between them.
            HStack(spacing: 0) {
                swatch(nil)
                ForEach(LeoAppearanceColor.allCases, id: \.self) { color in
                    Spacer(minLength: 2)
                    swatch(color)
                }
            }
        }
    }

    private func swatch(_ color: LeoAppearanceColor?) -> some View {
        let isCurrent = color == model.colorPick
        return Button { Task { await model.pickColor(color) } } label: {
            ZStack {
                Circle().fill(color?.swiftUIColor ?? Color.secondary.opacity(0.15))
                if color == nil {
                    Image(systemName: "line.diagonal").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .padding(2)
            .overlay(Circle().strokeBorder(isCurrent ? Color.primary : .clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color?.displayName ?? model.noneColorLabel)
        .accessibilityLabel(color?.displayName ?? model.noneColorLabel)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .disabled(model.isSaving)
    }

    private var sourceBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(model.emojiSourceText) } icon: { Image(systemName: "face.smiling") }
            Label { Text(model.colorSourceText) } icon: {
                Circle().fill(model.appearance?.color?.swiftUIColor ?? Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
            }
            Text("A pick here overrides the rules for this agent only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .labelStyle(LeoAppearanceSourceLabelStyle())
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LeoAppearanceSourceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 14).foregroundStyle(.secondary)
            configuration.title.lineLimit(2)
        }
    }
}
