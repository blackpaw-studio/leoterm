import LeoKit
import SwiftUI

/// What the inbox asks of its window: show an agent, show its chat, how many
/// agents are working (for the empty state).
struct LeoInboxActions {
    var goToAgent: (LeoAgentID) -> Void = { _ in }
    var openChat: (LeoAgentID) -> Void = { _ in }
    var runningCount: () -> Int = { 0 }
}

/// The window's content area while the sidebar's Inbox row is selected.
struct LeoInboxContent: View {
    @ObservedObject var terminals: LeoWindowTerminals
    let inbox: LeoInboxModel
    let actions: LeoInboxActions

    var body: some View {
        if terminals.isInboxSelected { LeoInboxView(model: inbox, actions: actions) }
    }
}

/// Option A: a header (title, summary, filter, Clear Finished) over a list
/// of what needs you and what finished since you looked, and the selected
/// item's detail beside it.
struct LeoInboxView: View {
    @ObservedObject var model: LeoInboxModel
    let actions: LeoInboxActions

    private static let listWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.shownBlocked.isEmpty && model.shownFinished.isEmpty {
                LeoInboxEmptyState(runningCount: actions.runningCount())
            } else {
                HStack(spacing: 0) {
                    LeoInboxList(model: model)
                        .frame(width: Self.listWidth)
                    Divider()
                    detail
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(LeoInboxKeys(perform: perform))
        .onAppear { if model.selection == nil, let first = model.selectedItem { model.select(first.id) } }
        .accessibilityIdentifier("inbox")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Inbox").font(.title3.weight(.semibold))
                Text(LeoInboxPresentation.summary(model.inbox.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inbox.summary")
            }
            Spacer(minLength: 12)
            Picker("Show", selection: $model.filter) {
                Text("All").tag(LeoInboxModel.Filter.all)
                Text("Needs you \(model.inbox.blocked.count)").tag(LeoInboxModel.Filter.needsYou)
                Text("Finished \(model.inbox.finished.filter(\.isUnread).count)").tag(LeoInboxModel.Filter.finished)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("Clear Finished") { model.clearFinished() }
                .disabled(!model.inbox.finished.contains(where: \.isUnread))
                .accessibilityIdentifier("inbox.clearFinished")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let item = model.selectedItem {
            LeoInboxDetail(model: model, item: item, actions: actions)
                .id(item.id)
        } else {
            Spacer()
        }
    }

    // MARK: Keyboard

    private func perform(_ action: LeoInboxKeyAction) -> Bool {
        let shown = model.shownBlocked + model.shownFinished
        guard let item = model.selectedItem, let index = shown.firstIndex(where: { $0.id == item.id }) else { return false }
        switch action {
        case .moveUp:
            model.select(shown[max(0, index - 1)].id)
        case .moveDown:
            model.select(shown[min(shown.count - 1, index + 1)].id)
        case .submit:
            return submit(item)
        case .goToAgent:
            actions.goToAgent(item.id)
        case .clearItem:
            guard !item.isBlocked else { return false }
            let next = shown.indices.contains(index + 1) ? shown[index + 1] : (index > 0 ? shown[index - 1] : nil)
            model.clear([item])
            model.select(next?.id)
        }
        return true
    }

    /// ↩ answers the selected ask when its answer is ready.
    private func submit(_ item: LeoInboxItem) -> Bool {
        guard case .chatAsk(let message) = item.kind else { return false }
        if message.input?.kind == .questions {
            guard model.questionsDraft(for: message.id)?.isComplete == true else { return false }
            Task { await model.submitQuestions(messageID: message.id) }
        } else {
            guard model.askAnswer(for: message.id) != nil else { return false }
            Task { await model.submitAsk(messageID: message.id) }
        }
        return true
    }
}

// MARK: Empty state

private struct LeoInboxEmptyState: View {
    let runningCount: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.green)
            Text("You're all caught up").font(.title3.weight(.semibold))
            Text(runningCount > 0 ? "\(runningCount) agent\(runningCount == 1 ? " is" : "s are") working." : "No agents are working.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox.empty")
    }
}
