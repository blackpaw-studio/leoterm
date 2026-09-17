import SwiftUI

/// Spotlight-style body for `LeoAgentPalettePanel`: a search field over a
/// keyboard/mouse-navigable row list built from `LeoAgentPaletteModel.rows`.
/// The search field is `LeoAgentPaletteSearchField` (a bridged `NSTextField`),
/// not a plain SwiftUI `TextField` -- see its doc for why ↑/↓/Return/Esc
/// need to be intercepted at the field-editor level.
struct LeoAgentPaletteView: View {
    @ObservedObject var model: LeoAgentPaletteModel
    let onCommit: (LeoPickerChoice) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            rowList
            if let error = model.attachError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 640)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)
            LeoAgentPaletteSearchField(
                text: $model.filterText,
                onMoveUp: { model.moveSelection(by: -1) },
                onMoveDown: { model.moveSelection(by: 1) },
                onSubmit: commitSelection,
                onCancel: { onCommit(.cancel) }
            )
        }
        .padding(16)
    }

    private var rowList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                        LeoAgentPaletteRowView(row: row, isSelected: index == model.selectedIndex, onRetry: onRetry)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.select(index)
                                commitSelection()
                            }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: model.selectedIndex) { newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func commitSelection() {
        guard let choice = model.confirm() else { return }
        onCommit(choice)
    }
}

private struct LeoAgentPaletteRowView: View {
    let row: LeoAgentPaletteModel.Row
    let isSelected: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch row {
        case .agent(let agentRow):
            agentContent(agentRow)
        case .newAgent:
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            Text("New Agent…")
        case .plainShell:
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text("Plain Shell")
        case .status(let text, let hint, let canRetry):
            statusContent(text: text, hint: hint, canRetry: canRetry)
        }
    }

    @ViewBuilder private func agentContent(_ agentRow: LeoAgentRow) -> some View {
        activityDot(agentRow)
        VStack(alignment: .leading, spacing: 2) {
            Text(agentRow.name).font(.body)
            if let repo = agentRow.repo, !repo.isEmpty {
                Text(repo).font(.caption).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 8)
        if case .remote(let name) = agentRow.host {
            Text(name)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func activityDot(_ agentRow: LeoAgentRow) -> some View {
        switch agentRow.activity {
        case .working:
            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Working")
        case .idle:
            Circle().fill(.gray).frame(width: 7, height: 7).accessibilityLabel("Idle")
        case .unknown:
            Color.clear.frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func statusContent(text: String, hint: String?, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.body).foregroundStyle(.secondary)
            if let hint, !hint.isEmpty {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 8)
        if canRetry {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderless)
        }
    }
}
