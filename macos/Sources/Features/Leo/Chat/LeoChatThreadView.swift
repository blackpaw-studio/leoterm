import Combine
import LeoKit
import SwiftUI

/// The scrolling thread, oldest at the top; it stays on the newest message
/// unless the reader scrolled up (`LeoChatScrollPin`), and pages older ones
/// in on request.
struct LeoChatThreadView: View {
    @ObservedObject var chat: LeoChatPaneModel
    @State private var pin = LeoChatScrollPin()
    /// What "Today" means in the time headers; refreshed at midnight and on a time-zone change.
    @State private var now = Date()

    private static let bottomID = "leo-chat-bottom"
    private static let scrollSpace = "leo-chat-scroll"

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        olderMessages
                        let items = LeoChatTranscript.items(for: chat.timeline.messages)
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(for: item)
                                .padding(.top, LeoChatTranscript.spacing(above: item, after: index > 0 ? items[index - 1] : nil))
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(12)
                    .background(metricsReader(viewport: viewport.size))
                }
                .coordinateSpace(name: Self.scrollSpace)
                .overlay { emptyState }
                .onPreferenceChange(LeoChatScrollMetricsKey.self) { metrics in
                    guard let metrics else { return }
                    let step = pin.measured(metrics)
                    pin = step.pin
                    if step.scrollToBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onReceive(Self.dayChanges) { _ in now = Date() }
                .onChange(of: chat.agent) { _ in pin = pin.reset() }
                .onChange(of: chat.timeline.taskFilter) { _ in pin = pin.reset() }
            }
        }
    }

    private static let dayChanges = NotificationCenter.default
        .publisher(for: .NSCalendarDayChanged)
        .merge(with: NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange))

    @ViewBuilder private func row(for item: LeoChatTranscript.Item) -> some View {
        switch item {
        case .timeHeader(let date, _): LeoChatTimeHeader(date: date, now: now)
        case .message(let message, let position): LeoChatMessageRow(message: message, position: position, chat: chat)
        }
    }

    /// Reports where the content sits in the scroll view; `viewport` is
    /// part of the value so a viewport-only resize reports too.
    private func metricsReader(viewport: CGSize) -> some View {
        GeometryReader { content in
            let frame = content.frame(in: .named(Self.scrollSpace))
            Color.clear.preference(
                key: LeoChatScrollMetricsKey.self,
                value: LeoChatScrollMetrics(contentMinY: frame.minY, contentHeight: frame.height, viewport: viewport)
            )
        }
    }

    @ViewBuilder private var olderMessages: some View {
        if chat.isLoadingOlder {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.bottom, LeoChatTranscript.groupSpacing)
        } else if chat.timeline.hasMore {
            Button("Load Earlier Messages") { Task { await chat.loadOlder() } }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
                .padding(.bottom, LeoChatTranscript.groupSpacing)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if chat.timeline.messages.isEmpty {
            if chat.isLoading {
                ProgressView()
            } else if let error = chat.loadError {
                VStack(spacing: 8) {
                    Text("Couldn't load messages").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { Task { await chat.retry() } }
                }
                .padding(24)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(chat.timeline.taskFilter == nil ? "No messages yet" : "No cards for this task").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LeoChatScrollMetricsKey: PreferenceKey {
    static let defaultValue: LeoChatScrollMetrics? = nil

    static func reduce(value: inout LeoChatScrollMetrics?, nextValue: () -> LeoChatScrollMetrics?) {
        value = nextValue() ?? value
    }
}
