import LeoKit
import SwiftUI

/// The scrolling thread, oldest at the top; it stays on the newest message
/// unless the reader scrolled up (`LeoChatScrollPin`), and pages older ones
/// in on request.
struct LeoChatThreadView: View {
    @ObservedObject var chat: LeoChatPaneModel
    @State private var pin = LeoChatScrollPin()

    private static let bottomID = "leo-chat-bottom"
    private static let scrollSpace = "leo-chat-scroll"

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        olderMessages
                        ForEach(chat.timeline.messages) { message in
                            LeoChatMessageRow(message: message, chat: chat).id(message.id)
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
                .onChange(of: chat.agent) { _ in pin = pin.reset() }
                .onChange(of: chat.timeline.taskFilter) { _ in pin = pin.reset() }
            }
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
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if chat.timeline.hasMore {
            Button("Load Earlier Messages") { Task { await chat.loadOlder() } }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
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
