import LeoKit
import SwiftUI

/// NEEDS YOU, then FINISHED SINCE YOU LOOKED (with Clear).
struct LeoInboxList: View {
    @ObservedObject var model: LeoInboxModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !model.shownBlocked.isEmpty {
                    sectionHeader("NEEDS YOU", count: model.shownBlocked.count)
                    ForEach(model.shownBlocked) { row($0) }
                }
                if !model.shownFinished.isEmpty {
                    finishedHeader
                    ForEach(model.shownFinished) { row($0) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func row(_ item: LeoInboxItem) -> some View {
        Button { model.select(item.id) } label: {
            LeoInboxRow(item: item, isSelected: model.selectedItem?.id == item.id)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inbox.row.\(item.id.name)")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.orange))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var finishedHeader: some View {
        HStack {
            Text("FINISHED SINCE YOU LOOKED")
            Spacer()
            Button("Clear") { model.clearFinished() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(!model.inbox.finished.contains(where: \.isUnread))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}

struct LeoInboxRow: View {
    let item: LeoInboxItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            LeoInboxSymbol(item: item)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.agent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let age = LeoInboxPresentation.age(of: item.at, now: Date()) {
                        Text(age).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                Text(LeoInboxPresentation.headline(item))
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.isBlocked ? Color.primary : Color.secondary)
                    .lineLimit(item.isBlocked ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 3)
                LeoInboxMeta(item: item)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if !item.isBlocked && item.isUnread {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 0, y: 15)
                    .accessibilityLabel("Unread")
            }
        }
        .opacity(!item.isBlocked && !item.isUnread && !isSelected ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}

/// The project tag, the machine, and where it came from.
struct LeoInboxMeta: View {
    let item: LeoInboxItem

    var body: some View {
        HStack(spacing: 5) {
            if let project = item.projectLabel {
                Text(project)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.secondary.opacity(0.15)))
            }
            Text(item.machine)
            if let source = LeoInboxPresentation.sourceLabel(item.kind) {
                Text("·")
                Text(source)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The kind's glyph: ask bubble, hand, check, or error triangle.
struct LeoInboxSymbol: View {
    let item: LeoInboxItem

    var body: some View {
        Image(systemName: name).foregroundStyle(color).font(.system(size: 14))
    }

    private var name: String {
        switch item.kind {
        case .chatAsk(let message): message.kind == .permission ? "hand.raised.fill" : "questionmark.bubble.fill"
        case .permission: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .finished: item.isError ? "exclamationmark.triangle.fill" : "checkmark.circle"
        }
    }

    private var color: Color {
        switch item.kind {
        case .finished: item.isError ? .red : .green
        default: .orange
        }
    }
}
