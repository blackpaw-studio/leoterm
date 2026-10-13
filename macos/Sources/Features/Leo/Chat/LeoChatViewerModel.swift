import AppKit
import Foundation
import LeoKit

/// The file open in a window's chat pane, if any. It belongs to one agent's
/// thread and closes when that thread leaves the screen: Back, an agent
/// switch, or the chat closing.
@MainActor final class LeoChatViewerModel: ObservableObject {
    struct Shown: Equatable {
        let agent: LeoAgentID
        let document: LeoChatViewerDocument
    }

    @Published private(set) var shown: Shown?

    private let access: any LeoFileAccess
    private let openExternally: @MainActor (URL) -> Void
    /// Identifies the open whose answer still counts.
    private var token = 0

    init(
        access: any LeoFileAccess = LeoFileAccessor.local(),
        openExternally: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.access = access
        self.openExternally = openExternally
    }

    /// Waits for `download`, then shows the file in the viewer, or hands it
    /// to the default app when the viewer can't show it. A failed download
    /// (nil) does neither: the row already shows the reason. Closing, an
    /// agent switch or a later open while this one waits cancels it.
    func open(_ attachment: LeoChatAttachment, for agent: LeoAgentID, download: @escaping () async -> URL?) async {
        token += 1
        let mine = token
        guard let url = await download(), mine == token else { return }
        let document = await LeoChatViewerDocument.load(attachment: attachment, url: url, access: access)
        guard mine == token else { return }
        guard let document else {
            openExternally(url)
            return
        }
        shown = Shown(agent: agent, document: document)
    }

    /// The open file, only while `agent`'s thread is the one shown.
    func document(for agent: LeoAgentID?) -> LeoChatViewerDocument? {
        guard let shown, shown.agent == agent else { return nil }
        return shown.document
    }

    func close() {
        token += 1
        if shown != nil { shown = nil }
    }

    /// The window now shows `agent`'s content (nil: none).
    func agentChanged(to agent: LeoAgentID?) {
        guard shown?.agent != agent else { return }
        close()
    }
}
