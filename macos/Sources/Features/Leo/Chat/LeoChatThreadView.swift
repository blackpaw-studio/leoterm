import LeoKit
import SwiftUI

/// The scrolling thread, oldest at the top; it follows the newest message
/// and pages older ones in on request.
struct LeoChatThreadView: View {
    @ObservedObject var chat: LeoChatPaneModel

    private static let bottomID = "leo-chat-bottom"

    var body: some View {
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
            }
            .overlay { emptyState }
            .onChange(of: chat.timeline.newest?.id) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
