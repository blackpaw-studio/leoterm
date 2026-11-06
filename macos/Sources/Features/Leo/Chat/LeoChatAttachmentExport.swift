import AppKit
import LeoKit

/// Saving a chat attachment outside Leo (B-346): dragged to Finder as a
/// file promise, or written through "Download to…". Both start from the
/// attachment's cached download (`LeoChatPaneModel.downloadedFile`), so a
/// remote machine's file comes over the same daemon connection as a click,
/// and publish that original through B-279's `LeoFileExport` -- never the
/// cropped bubble image (D-672).
enum LeoChatAttachmentExport {
    static let downloadMenuTitle = "Download to…"

    /// The attachment could not be downloaded; `errorDescription` is the
    /// pane's reason ("box isn't connected.").
    struct Unavailable: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The name Finder and the save panel start from: the attachment's
    /// own, with any folder part dropped.
    static func fileName(for attachment: LeoChatAttachment) -> String {
        LeoChatPresentation.safeFilename(attachment.filename, fallback: attachment.id)
    }

    /// The promise Finder gets on a drag. The machine is fixed here, when
    /// the drag starts: `host` nil is the shown agent's, and the pane may
    /// show another by the time the file is dropped.
    @MainActor static func promise(for attachment: LeoChatAttachment, host: LeoHostID?, chat: LeoChatPaneModel) -> LeoFilePromise {
        let host = host ?? chat.agent?.host
        let name = fileName(for: attachment)
        return LeoFilePromise(fileName: name) { [weak chat] url in
            guard let chat else { throw LeoFileAccessError.closed }
            try await drop(attachment, host: host, chat: chat, into: url)
        }
    }

    /// Writes the attachment to `url`, or to a numbered name beside it
    /// when that is taken (Finder's keep-both).
    @MainActor static func drop(_ attachment: LeoChatAttachment, host: LeoHostID?, chat: LeoChatPaneModel, into url: URL) async throws {
        try await perform(attachment, chat: chat) {
            let original = try await original(of: attachment, host: host, chat: chat)
            try await export(original, to: url)
        }
    }

    /// Writes the attachment to `destination`, replacing what is there:
    /// the save panel has already confirmed that. The copy is staged
    /// beside it first, so a failure leaves the old file untouched.
    @MainActor static func save(_ attachment: LeoChatAttachment, host: LeoHostID?, chat: LeoChatPaneModel, to destination: URL) async throws {
        try await perform(attachment, chat: chat) {
            let original = try await original(of: attachment, host: host, chat: chat)
            try await replace(destination, with: original)
        }
    }

    /// The panel "Download to…" opens, named for the original file. The
    /// extension stays visible and editable; the folder is left to macOS,
    /// which remembers the last one.
    @MainActor static func makeSavePanel(for attachment: LeoChatAttachment) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(for: attachment)
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.title = "Download Attachment"
        return panel
    }

    /// Shows the save panel as a sheet on `window` (a window-less panel
    /// runs on its own) and saves once a file is chosen.
    @MainActor static func presentSavePanel(
        for attachment: LeoChatAttachment, host: LeoHostID?, chat: LeoChatPaneModel, in window: NSWindow?
    ) {
        let host = host ?? chat.agent?.host
        let panel = makeSavePanel(for: attachment)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak chat] response in
            guard response == .OK, let url = panel.url, let chat else { return }
            Task { try? await save(attachment, host: host, chat: chat, to: url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: Plumbing

    /// Runs `body`, showing any failure as the pane's notice as well as
    /// throwing it (Finder reports a failed drop itself).
    @MainActor private static func perform(
        _ attachment: LeoChatAttachment, chat: LeoChatPaneModel, _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            chat.showNotice("Couldn't save \(fileName(for: attachment)): \(LeoFileExport.message(for: error))")
            throw error
        }
    }

    @MainActor private static func original(of attachment: LeoChatAttachment, host: LeoHostID?, chat: LeoChatPaneModel) async throws -> URL {
        if let url = await chat.downloadedFile(attachment, from: host) { return url }
        if case .failed(let reason) = chat.attachmentFiles[attachment.id] { throw Unavailable(reason: reason) }
        throw Unavailable(reason: "This attachment is no longer available.")
    }

    /// The blocking file writes run off the main actor.
    private static func export(_ original: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try await LeoFileExport.download(
                remotePath: original.path(percentEncoded: false), to: destination,
                access: LeoFileAccessor.local()
            )
        }.value
    }

    private static func replace(_ destination: URL, with original: URL) async throws {
        let folder = destination.deletingLastPathComponent()
        let manager = FileManager.default
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appending(path: destination.lastPathComponent, directoryHint: .notDirectory)
        try await export(original, to: staged)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}
