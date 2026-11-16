import AppKit

/// A file chooser the browser can show for a page's `<input type=file>`.
/// The real one is a standalone `NSOpenPanel`; tests inject a fake.
@MainActor protocol LeoBrowserFilePicking {
    /// Shows the chooser and calls `completion` with the chosen URLs, or
    /// nil when the user cancels. The returned session dismisses it early.
    func present(
        allowsMultipleSelection: Bool, allowsDirectories: Bool,
        completion: @escaping @MainActor ([URL]?) -> Void
    ) -> any LeoBrowserFilePickSession
}

@MainActor protocol LeoBrowserFilePickSession {
    /// Dismisses the chooser without a choice. The completion given to
    /// `present` then fires with nil, or may not fire at all.
    func dismiss()
}

/// A standalone, non-modal open panel. Not a window sheet: the browser
/// pane shares its window with terminals, and an agent-driven click must
/// never freeze that window behind a sheet.
@MainActor struct LeoOpenPanelFilePicker: LeoBrowserFilePicking {
    func present(
        allowsMultipleSelection: Bool, allowsDirectories: Bool,
        completion: @escaping @MainActor ([URL]?) -> Void
    ) -> any LeoBrowserFilePickSession {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.urls : nil) }
        }
        return Session(panel: panel)
    }

    private struct Session: LeoBrowserFilePickSession {
        let panel: NSOpenPanel

        func dismiss() { panel.cancel(nil) }
    }
}

/// One page's pending chooser. It answers the page's completion handler
/// exactly once, whether the user chooses, cancels, or the tab closes.
@MainActor final class LeoBrowserFilePick {
    var isFinished: Bool { completion == nil }
    private var completion: (@MainActor ([URL]?) -> Void)?
    private var session: (any LeoBrowserFilePickSession)?

    init(completion: @escaping @MainActor ([URL]?) -> Void) {
        self.completion = completion
    }

    func attach(_ session: any LeoBrowserFilePickSession) {
        self.session = session
    }

    func finish(_ urls: [URL]?) {
        guard let completion else { return }
        self.completion = nil
        session = nil
        completion(urls)
    }

    /// The tab went away: dismiss the panel and answer nil.
    func abandon() {
        let session = session
        finish(nil)
        session?.dismiss()
    }
}
