import AppKit
import Foundation
import LeoKit

/// The file open in a window's chat pane, if any. It belongs to one agent's
/// thread and closes when that thread leaves the screen: Back, an agent
/// switch, or the chat closing. It shows in the pane or, from there or
/// straight from an attachment's menu, over the whole window.
@MainActor final class LeoChatViewerModel: ObservableObject {
    /// Where the open file is drawn. Full window remembers whether the
    /// in-pane viewer was showing it first, so leaving goes back there.
    enum Presentation: Equatable {
        case pane
        case fullWindow(fromPane: Bool)
    }

    struct Shown: Equatable {
        let agent: LeoAgentID
        let document: LeoChatViewerDocument
        let presentation: Presentation
        /// The message's other images the viewer can step through, in order,
        /// this document's among them. Empty for a file opened alone.
        var gallery: [LeoChatAttachment] = []
    }

    /// Where the shown image sits among its message's images.
    struct GalleryPosition: Equatable {
        let index: Int
        let count: Int
    }

    @Published private(set) var shown: Shown?

    private let access: any LeoFileAccess
    private let openExternally: @MainActor (URL) -> Void
    /// Identifies the open whose answer still counts.
    private var token = 0
    /// The agent whose open is waiting on its download, if one is.
    private var pendingAgent: LeoAgentID?
    /// Downloads a gallery's other images; set by the `open` that gave the gallery.
    private var downloadGalleryItem: ((LeoChatAttachment) async -> URL?)?
    /// The gallery index a step is still loading, so a second step goes on from it.
    private var pendingIndex: Int?

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
    func open(
        _ attachment: LeoChatAttachment,
        for agent: LeoAgentID,
        fullWindow: Bool = false,
        gallery: [LeoChatAttachment] = [],
        download: @escaping () async -> URL?,
        downloadGalleryItem: ((LeoChatAttachment) async -> URL?)? = nil
    ) async {
        token += 1
        let mine = token
        pendingAgent = agent
        pendingIndex = nil
        guard let url = await download(), mine == token else { return settle(mine) }
        let document = await LeoChatViewerDocument.load(attachment: attachment, url: url, access: access)
        guard mine == token else { return settle(mine) }
        settle(mine)
        guard let document else {
            openExternally(url)
            return
        }
        let siblings = gallery.count > 1 && gallery.contains { $0.id == attachment.id } ? gallery : []
        self.downloadGalleryItem = downloadGalleryItem
        shown = Shown(
            agent: agent, document: document, presentation: fullWindow ? .fullWindow(fromPane: false) : .pane, gallery: siblings
        )
    }

    /// The shown image's place among its message's images; nil when there is
    /// no one to step to. While a step loads, the place it is going to.
    var galleryPosition: GalleryPosition? {
        guard let shown, shown.gallery.count > 1, let index = pendingIndex ?? galleryIndex(of: shown) else { return nil }
        return GalleryPosition(index: index, count: shown.gallery.count)
    }

    /// Shows the image `delta` places on in the message's gallery. It stops
    /// at either end, and a failed download keeps the current image. Closing
    /// or an agent switch while it loads drops it; a later step supersedes it.
    func step(_ delta: Int) async {
        guard let start = shown, let position = galleryPosition, let download = downloadGalleryItem else { return }
        let target = position.index + delta
        guard start.gallery.indices.contains(target) else { return }
        let attachment = start.gallery[target]
        token += 1
        let mine = token
        pendingAgent = start.agent
        pendingIndex = target
        guard let url = await download(attachment), mine == token else { return settle(mine) }
        let document = await LeoChatViewerDocument.load(attachment: attachment, url: url, access: access)
        guard mine == token else { return settle(mine) }
        settle(mine)
        guard let document, let current = shown else { return }
        shown = Shown(agent: current.agent, document: document, presentation: current.presentation, gallery: current.gallery)
    }

    private func galleryIndex(of shown: Shown) -> Int? {
        shown.gallery.firstIndex { $0.id == shown.document.attachmentID }
    }

    /// The file the pane's viewer layout shows, only while `agent`'s thread
    /// is the one shown. A file opened straight to full window leaves the
    /// pane on the thread.
    func document(for agent: LeoAgentID?) -> LeoChatViewerDocument? {
        guard let shown, shown.agent == agent, shown.presentation != .fullWindow(fromPane: false) else { return nil }
        return shown.document
    }

    var isFullWindow: Bool {
        if case .fullWindow = shown?.presentation { return true }
        return false
    }

    var fullWindowDocument: LeoChatViewerDocument? {
        isFullWindow ? shown?.document : nil
    }

    /// Expands the in-pane viewer over the window.
    func enterFullWindow() {
        guard let shown, shown.presentation == .pane else { return }
        self.shown = Shown(agent: shown.agent, document: shown.document, presentation: .fullWindow(fromPane: true), gallery: shown.gallery)
    }

    /// Leaves full window for where it was opened from. True when the pane
    /// viewer is back; false when the user is back at the thread (the file
    /// closed) or wasn't in full window at all.
    @discardableResult
    func exitFullWindow() -> Bool {
        guard let shown, case .fullWindow(let fromPane) = shown.presentation else { return false }
        guard fromPane else {
            close()
            return false
        }
        self.shown = Shown(agent: shown.agent, document: shown.document, presentation: .pane, gallery: shown.gallery)
        return true
    }

    func close() {
        token += 1
        pendingAgent = nil
        pendingIndex = nil
        downloadGalleryItem = nil
        if shown != nil { shown = nil }
    }

    /// The window now shows `agent`'s content (nil: none). Anything open or
    /// still opening for another agent is dropped, so it can't surface when
    /// that agent comes back.
    func agentChanged(to agent: LeoAgentID?) {
        guard let owner = pendingAgent ?? shown?.agent, owner != agent else { return }
        close()
    }

    /// Open `mine` has finished waiting; a newer open keeps its own claim.
    private func settle(_ mine: Int) {
        if mine == token {
            pendingAgent = nil
            pendingIndex = nil
        }
    }
}
