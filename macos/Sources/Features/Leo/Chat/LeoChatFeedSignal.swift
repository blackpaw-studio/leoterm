import Foundation
import LeoKit

/// What the sidebar feed forwards to the chat pane from the event stream.
enum LeoChatFeedSignal: Equatable, Sendable {
    case event(LeoChatEvent)
    /// Events may have been lost: reload the shown thread.
    case resync

    /// A hello follows every (re)subscribe and a daemon restart; a gap or
    /// a snapshot means the stream skipped ahead.
    init?(_ event: LeoObserveEvent) {
        switch event {
        case .chat(_, let chat): self = .event(chat)
        case .hello, .gap, .snapshot: self = .resync
        default: return nil
        }
    }
}

/// One signal with the host whose stream it came from.
struct LeoChatFeedDelivery: Sendable {
    let host: LeoHostID
    let signal: LeoChatFeedSignal
}

extension LeoChatPaneModel {
    func handle(_ delivery: LeoChatFeedDelivery) async {
        switch delivery.signal {
        case .event(let event): await receive(event, host: delivery.host)
        case .resync: await resync(host: delivery.host)
        }
    }

    /// Downloaded attachments and unsent voice notes; the system clears it.
    nonisolated static var defaultAttachmentDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "LeoChat", directoryHint: .isDirectory)
    }

    nonisolated static func makeClient(socketPath: String, transport: any LeoDaemonTransport) -> LeoChatHTTPClient {
        LeoChatHTTPClient(transport: LeoSocketChatTransport(socketPath: socketPath, transport: transport))
    }
}
