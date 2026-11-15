import AppKit

/// The tab's presentation commands (B-278): View ▸ Show Raw / Show
/// Rendered (⌥⌘U), View ▸ Actual Size / Zoom to Fit (⌥⌘0), and File ▸
/// Show in Finder / Download (⌥⇧⌘R), each also on the header or Can't
/// Preview.
extension LeoEditorPaneViewController {
    /// Whether Rendered/Raw applies to the open file.
    var canToggleRaw: Bool {
        guard let document = model.document else { return false }
        return LeoEditorPresentation.canToggleRaw(kind: document.kind, textLength: textView.string.utf16.count, isPreview: document.isPreview)
    }

    var canZoom: Bool { contentHost.imagePreview != nil }

    /// Fit is showing (so the command reads Actual Size).
    var isFitted: Bool { contentHost.imagePreview?.zoom.mode == .fit }

    var headerPresentation: LeoEditorHeaderView.Presentation {
        LeoEditorHeaderView.Presentation(
            showsRawToggle: canToggleRaw, isRaw: presentation.isRaw, showsZoom: canZoom, isFitted: isFitted
        )
    }

    /// Switches Rendered ↔ Raw, keeping focus in the pane if it was there.
    /// Rendering draws the buffer as it is now, edits included.
    func toggleRawPresentation() {
        guard canToggleRaw else { return NSSound.beep() }
        presentation = presentation.toggled()
        refreshContent(rerender: true)
        refreshChrome()
    }

    func toggleImageZoom() {
        guard let image = contentHost.imagePreview else { return NSSound.beep() }
        image.toggleZoom()
        refreshChrome()
    }

    /// A local file is shown in Finder; a remote one downloads to
    /// ~/Downloads (keeping both on a clash), then is shown there.
    func revealOrDownload() {
        guard let document = model.document else { return NSSound.beep() }
        guard document.fileID.host != .local else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.fileID.path)])
            return
        }
        let window = view.window
        Task {
            do {
                let downloaded = try await document.download(into: Self.downloadsFolder)
                NSWorkspace.shared.activateFileViewerSelecting([downloaded])
            } catch {
                LeoEditorAlerts.presentError(error, on: window)
            }
        }
    }

    func perform(_ action: LeoUnavailablePreviewView.Action) {
        switch action {
        case .reveal: revealOrDownload()
        case .retry:
            guard let document = model.document else { return }
            Task { await document.reload() }
        }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}
