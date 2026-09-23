import AppKit

/// The one gate every close of a tab, a window or the app goes through,
/// so unsaved editor edits are never dropped. A close that can ask (Close
/// Tab, Close Window, ⌘W, Close Other Tabs, Close All Windows, Quit) asks
/// about each editor with unsaved edits in turn -- Save / Don't Save /
/// Cancel, on its window, brought forward first -- and goes ahead once
/// every one is resolved; Cancel (or a Save that can't go through) drops
/// it. A close that can't ask keeps the tab instead: see
/// `TerminalController.leoKeepForUnsavedEdits()`.
///
/// The user can always leave: asked to close an editor that's waiting on
/// its disk or connection (a save or read that hasn't come back) rather
/// than on its prompt, the gate offers to leave anyway, losing that
/// editor's unsaved edits (`offerToLeave`). No timers: it's the user's call.
@MainActor final class LeoUnsavedEditorsGate {
    struct Entry {
        let editor: LeoEditorPaneModel
        /// Brings the editor's window forward, so its sheet is seen.
        let bringForward: @MainActor () -> Void
    }

    /// What the close that's waiting would do.
    enum Leaving: Sendable {
        case close
        case quit
    }

    /// Asks whether to leave anyway while `entry` waits on its disk or
    /// connection. `true`: leave, losing its unsaved edits.
    typealias OfferToLeave = @MainActor (_ entry: Entry, _ leaving: Leaving) async -> Bool

    /// A close in progress: the editors it asks about in turn, and the one
    /// it's on.
    private final class Resolution {
        let entries: [Entry]
        let completion: @MainActor (Bool) -> Void
        var current: Entry?
        var isFinished = false

        init(entries: [Entry], completion: @escaping @MainActor (Bool) -> Void) {
            self.entries = entries
            self.completion = completion
        }

        func includes(_ editor: LeoEditorPaneModel) -> Bool {
            entries.contains { $0.editor === editor }
        }
    }

    private let offerToLeave: OfferToLeave
    private var resolutions: [Resolution] = []
    private var isOffering = false

    init(offerToLeave: @escaping OfferToLeave = LeoEditorAlerts.offerToLeave) {
        self.offerToLeave = offerToLeave
    }

    /// While any close is asking about (or saving) its editors.
    var isAsking: Bool { !resolutions.isEmpty }

    static func hasUnsavedEdits(_ editor: LeoEditorPaneModel) -> Bool {
        editor.document?.isDirty == true
    }

    /// `true` when the gate took the close over; `completion` then runs
    /// once, later, with whether it may go ahead. `false`: nothing to ask,
    /// so the close goes ahead now.
    ///
    /// One close per editor at a time. Another close of an editor that's
    /// already being asked about is dropped (`false`) -- the user is
    /// answering -- unless that editor is waiting on its disk or connection
    /// instead: then the user is offered to leave anyway.
    func deferClose(of entries: [Entry], leaving: Leaving = .close, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        let unsaved = entries.filter { Self.hasUnsavedEdits($0.editor) }
        guard !unsaved.isEmpty else { return false }
        let busy = resolutions.filter { resolution in unsaved.contains { resolution.includes($0.editor) } }
        guard busy.isEmpty else {
            let stuck = busy.lazy.compactMap { resolution in
                resolution.current.map { (resolution, $0) }
            }.first { _, current in
                !current.editor.isConfirming && unsaved.contains { $0.editor === current.editor }
            }
            if let (resolution, entry) = stuck, !isOffering {
                offerToLeave(entry, stuckIn: resolution, leaving: leaving, completion: completion)
            } else {
                Task { completion(false) }
            }
            return true
        }
        run(Resolution(entries: unsaved, completion: completion))
        return true
    }

    /// Asks about each editor with unsaved edits in turn (closing it on
    /// Save or Don't Save). `false` at the first Cancel or failed Save,
    /// leaving that editor and the rest as they are.
    func resolve(_ entries: [Entry]) async -> Bool {
        await withCheckedContinuation { continuation in
            let deferred = deferClose(of: entries) { continuation.resume(returning: $0) }
            if !deferred { continuation.resume(returning: true) }
        }
    }

    // MARK: - Resolving

    private func run(_ resolution: Resolution) {
        resolutions.append(resolution)
        Task {
            for entry in resolution.entries where Self.hasUnsavedEdits(entry.editor) {
                resolution.current = entry
                entry.bringForward()
                let closed = await entry.editor.close()
                guard !resolution.isFinished else { return }
                resolution.current = nil
                guard closed else { return finish(resolution, goingAhead: false) }
            }
            finish(resolution, goingAhead: true)
        }
    }

    private func finish(_ resolution: Resolution, goingAhead: Bool) {
        guard !resolution.isFinished else { return }
        resolution.isFinished = true
        resolutions.removeAll { $0 === resolution }
        resolution.completion(goingAhead)
    }

    /// Leaving anyway drops the stuck editor's document without waiting for
    /// what's in flight, and ends the close that was waiting on it; the new
    /// close then goes ahead (any other editor with unsaved edits is still
    /// asked about when it runs).
    private func offerToLeave(
        _ entry: Entry, stuckIn stuck: Resolution, leaving: Leaving, completion: @escaping @MainActor (Bool) -> Void
    ) {
        isOffering = true
        Task {
            let leave = await offerToLeave(entry, leaving)
            isOffering = false
            // Only if it's still stuck: the save may have come back meanwhile.
            guard leave, !stuck.isFinished, stuck.current?.editor === entry.editor, !entry.editor.isConfirming else {
                return completion(false)
            }
            entry.editor.abandon()
            finish(stuck, goingAhead: false)
            completion(true)
        }
    }
}

extension LeoUnsavedEditorsGate {
    /// Quitting with unsaved editor edits; nil when there are none, and the
    /// quit goes on. Logging out, restarting or shutting down waits for the
    /// answers (`.terminateLater`, then `reply` exactly once): it goes on
    /// after Save or Don't Save, and is cancelled on Cancel. Any other quit
    /// -- ⌘Q, installing an update -- is cancelled now and `retry`d once
    /// they're resolved, so a second ⌘Q still reaches the gate (to leave
    /// anyway, if a save never comes back).
    func deferQuit(
        of entries: [Entry], isSystemQuit: Bool, reply: @escaping @MainActor (Bool) -> Void, retry: @escaping @MainActor () -> Void
    ) -> NSApplication.TerminateReply? {
        if isSystemQuit {
            return deferClose(of: entries, leaving: .quit, completion: reply) ? .terminateLater : nil
        }
        return deferClose(of: entries, leaving: .quit) { if $0 { retry() } } ? .terminateCancel : nil
    }
}

/// Why the app is quitting.
enum LeoQuitReason {
    /// Whether it's the system's quit -- logging out, restarting or
    /// shutting down -- from the quit Apple event's `why?` attribute.
    static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let why = event?.attributeDescriptor(forKeyword: "why?".fourCharCode) else { return false }
        switch why.typeCodeValue {
        case kAEShutDown, kAERestart, kAEReallyLogOut: return true
        default: return false
        }
    }
}
