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
/// editor's unsaved edits (`offerToLeave`). A pending quit that can't be
/// asked for again -- logging out, Ghostty's quit review -- offers that
/// itself, through the stuck editor's `leaveAnyway`. No timers: it's the
/// user's call.
@MainActor final class LeoUnsavedEditorsGate {
    struct Entry {
        let editor: LeoEditorPaneModel
        /// The editor's window, for sheets about it (nil: an app-modal alert).
        let window: @MainActor () -> NSWindow?
        /// Brings the editor's window forward, so its sheet is seen.
        let bringForward: @MainActor () -> Void

        init(
            editor: LeoEditorPaneModel,
            window: @escaping @MainActor () -> NSWindow? = { nil },
            bringForward: @escaping @MainActor () -> Void
        ) {
            self.editor = editor
            self.window = window
            self.bringForward = bringForward
        }
    }

    /// What the close that's waiting would do.
    enum Leaving: Sendable {
        case close
        case quit
    }

    /// Asks whether to leave anyway while `entry` waits on its disk or
    /// connection. `true`: leave, losing its unsaved edits.
    typealias OfferToLeave = @MainActor (_ entry: Entry, _ leaving: Leaving) async -> Bool

    /// A close in progress: the editors it asks about in turn -- every one
    /// it closes, re-checked for unsaved edits when its turn comes, so one
    /// edited meanwhile is asked about too -- and the one it's on.
    @MainActor private final class Resolution {
        let entries: [Entry]
        let leaving: Leaving
        /// It can't be asked for again (a pending quit): it offers to leave
        /// a stuck editor itself, through `LeoEditorPaneModel.leaveAnyway`.
        let offersToLeave: Bool
        let completion: @MainActor (Bool) -> Void
        var current: Entry?
        /// Which pass over `entries` is live: leaving a stuck editor starts
        /// a new one, and the stuck pass's close is then ignored.
        var pass = 0
        var isFinished = false

        init(entries: [Entry], leaving: Leaving, offersToLeave: Bool, completion: @escaping @MainActor (Bool) -> Void) {
            self.entries = entries
            self.leaving = leaving
            self.offersToLeave = offersToLeave
            self.completion = completion
        }

        func includes(_ editor: LeoEditorPaneModel) -> Bool {
            entries.contains { $0.editor === editor }
        }

        /// Stuck on `entry`: waiting on its disk or connection, not its prompt.
        func isStuck(on entry: Entry) -> Bool {
            !isFinished && current?.editor === entry.editor && !entry.editor.isConfirming
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
        deferClose(of: entries, leaving: leaving, offersToLeave: false, completion: completion)
    }

    /// `offersToLeave`: the close is a pending quit that can't be asked for
    /// again, so it offers to leave a stuck editor itself.
    private func deferClose(
        of entries: [Entry], leaving: Leaving, offersToLeave: Bool, completion: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
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
                offerToLeave(entry, stuckIn: resolution, closing: entries, leaving: leaving, offersToLeave: offersToLeave, completion: completion)
            } else {
                Task { completion(false) }
            }
            return true
        }
        run(Resolution(entries: entries, leaving: leaving, offersToLeave: offersToLeave, completion: completion))
        return true
    }

    /// Asks about each editor with unsaved edits in turn (closing it on
    /// Save or Don't Save). `false` at the first Cancel or failed Save,
    /// leaving that editor and the rest as they are. For Ghostty's quit
    /// review, inside a pending quit: it offers to leave a stuck editor
    /// itself.
    func resolve(_ entries: [Entry]) async -> Bool {
        await withCheckedContinuation { continuation in
            let deferred = deferClose(of: entries, leaving: .quit, offersToLeave: true) { continuation.resume(returning: $0) }
            if !deferred { continuation.resume(returning: true) }
        }
    }

    // MARK: - Resolving

    private func run(_ resolution: Resolution) {
        resolutions.append(resolution)
        advance(resolution)
    }

    /// A pass over the resolution's editors, from the first: the ones
    /// already closed (or left) no longer have unsaved edits.
    private func advance(_ resolution: Resolution) {
        resolution.pass += 1
        let pass = resolution.pass
        Task {
            for entry in resolution.entries where Self.hasUnsavedEdits(entry.editor) {
                resolution.current = entry
                if resolution.offersToLeave {
                    entry.editor.leaveAnyway = { [weak self] in self?.offerToLeave(entry, from: resolution) }
                }
                entry.bringForward()
                let closed = await entry.editor.close()
                guard !resolution.isFinished, resolution.pass == pass else { return }
                resolution.current = nil
                entry.editor.leaveAnyway = nil
                guard closed else { return finish(resolution, goingAhead: false) }
            }
            finish(resolution, goingAhead: true)
        }
    }

    private func finish(_ resolution: Resolution, goingAhead: Bool) {
        guard !resolution.isFinished else { return }
        resolution.isFinished = true
        resolution.current?.editor.leaveAnyway = nil
        resolutions.removeAll { $0 === resolution }
        resolution.completion(goingAhead)
    }

    /// From inside a pending quit (`LeoEditorPaneModel.leaveAnyway`):
    /// leaving drops the stuck editor's document without waiting for
    /// what's in flight, and the quit goes on to ask about the rest.
    /// Keep Waiting changes nothing, and the offer stays reachable.
    private func offerToLeave(_ entry: Entry, from resolution: Resolution) {
        guard !isOffering, resolution.isStuck(on: entry) else { return }
        isOffering = true
        Task {
            let leave = await offerToLeave(entry, resolution.leaving)
            isOffering = false
            // Only if it's still stuck: the save may have come back meanwhile.
            guard leave, resolution.isStuck(on: entry) else { return }
            entry.editor.leaveAnyway = nil
            entry.editor.abandon()
            resolution.current = nil
            advance(resolution)
        }
    }

    /// Leaving anyway drops the stuck editor's document without waiting for
    /// what's in flight, and ends the close that was waiting on it. That
    /// gives up only that editor's edits: the new close then asks about the
    /// rest of `closing` as usual, and their answers decide `completion`.
    private func offerToLeave(
        _ entry: Entry, stuckIn stuck: Resolution, closing: [Entry], leaving: Leaving, offersToLeave: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        isOffering = true
        Task {
            let leave = await offerToLeave(entry, leaving)
            isOffering = false
            // Only if it's still stuck: the save may have come back meanwhile.
            guard leave, stuck.isStuck(on: entry) else { return completion(false) }
            entry.editor.abandon()
            finish(stuck, goingAhead: false)
            let rest = closing.filter { $0.editor !== entry.editor }
            if !deferClose(of: rest, leaving: leaving, offersToLeave: offersToLeave, completion: completion) { completion(true) }
        }
    }
}

extension LeoUnsavedEditorsGate {
    /// Quitting with unsaved editor edits; nil when there are none, and the
    /// quit goes on. Logging out, restarting or shutting down waits for the
    /// answers (`.terminateLater`, then `reply` exactly once): it goes on
    /// after Save or Don't Save, and is cancelled on Cancel; if a save never
    /// comes back, the stuck editor offers to quit anyway (`leaveAnyway`).
    /// Any other quit -- ⌘Q, installing an update -- is cancelled now and
    /// `retry`d once they're resolved, so a second ⌘Q still reaches the
    /// gate (to leave anyway).
    func deferQuit(
        of entries: [Entry], isSystemQuit: Bool, reply: @escaping @MainActor (Bool) -> Void, retry: @escaping @MainActor () -> Void
    ) -> NSApplication.TerminateReply? {
        if isSystemQuit {
            return deferClose(of: entries, leaving: .quit, offersToLeave: true, completion: reply) ? .terminateLater : nil
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
