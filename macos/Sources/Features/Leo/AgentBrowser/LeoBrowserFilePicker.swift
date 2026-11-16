import AppKit

/// Who is asking for a file, and for what. Several agents' browsers can be
/// open at once, so the chooser says which agent and which site asked.
struct LeoBrowserFilePickRequest: Equatable {
    /// The agent whose browser holds the page.
    let agent: String
    /// The requesting frame's origin, already formatted for people.
    let origin: String
    let allowsMultipleSelection: Bool
    let allowsDirectories: Bool

    /// What the chooser says: "<agent> · <origin> wants to upload a file".
    var message: String {
        "\(agent) · \(origin) wants to upload a \(allowsDirectories ? "folder" : "file")"
    }

    /// `host` plus a non-default `port` (0 means the scheme's default), or
    /// "this page" when there is no host, as for `about:blank`.
    static func originLabel(host: String, port: Int) -> String {
        guard !host.isEmpty else { return "this page" }
        return port == 0 ? host : "\(host):\(port)"
    }
}

/// A file chooser the browser can show for a page's `<input type=file>`.
/// The real one is a standalone `NSOpenPanel`; tests inject a fake.
@MainActor protocol LeoBrowserFilePicking {
    /// Shows the chooser and calls `completion` with the chosen URLs, or
    /// nil when the user cancels. The returned session dismisses it early.
    func present(
        _ request: LeoBrowserFilePickRequest,
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
        _ request: LeoBrowserFilePickRequest,
        completion: @escaping @MainActor ([URL]?) -> Void
    ) -> any LeoBrowserFilePickSession {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        panel.canChooseDirectories = request.allowsDirectories
        panel.message = request.message
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
