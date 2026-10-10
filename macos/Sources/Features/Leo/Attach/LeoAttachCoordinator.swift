import Foundation

struct LeoAttachError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case executable(String)
        case invalidName
        case invalidDispatchID
        /// A dispatch attach ended with a failure: the exit code, and the
        /// line it printed.
        case dispatchAttachFailed(code: Int, detail: String?)
        case openFailed(String)
        /// The user kept what the content area showed (B-055). Nothing
        /// failed, so nothing is reported.
        case cancelled
    }

    let identity: LeoAgentIdentity
    let kind: Kind

    var message: String {
        switch kind {
        case .executable(let message), .openFailed(let message): message
        case .invalidName: "Agent names cannot contain NUL or newline characters"
        case .invalidDispatchID: "This dispatch has an id that can't be attached"
        case .dispatchAttachFailed(let code, let detail): detail.map { "\($0) (exit \(code))" } ?? "Dispatch attach exited with code \(code)"
        case .cancelled: "Cancelled"
        }
    }

    var isCancellation: Bool { kind == .cancelled }
}

private enum LeoAttachCoordinatorError: Error, LocalizedError {
    case missingSplitSource

    var errorDescription: String? {
        switch self {
        case .missingSplitSource: "A split request must name the surface it splits from"
        }
    }
}

@MainActor final class LeoAttachCoordinator {
    private let host: any AttachContentHost
    private let executable: () throws -> String
    /// Builds the shell command for a *remote* identity (an app-owned SSH
    /// attach via `LeoSSHCommand.attachShellCommand`). Local identities
    /// always go through `LeoAttachCommand.build(executable:identity:)`.
    private let remoteCommandBuilder: (LeoAgentIdentity) throws -> String
    /// What the daemon advertised; read when an attach command is built, so
    /// an attach before the hello arrives gets the unchanged command.
    private let daemonFeatures: (LeoHostID) -> LeoDaemonFeatures
    private let report: (LeoAttachError) -> Void
    private let lifecycleEventHandled: (AttachLifecycleEvent) -> Void
    private let focusedIdentityChanged: (LeoAgentIdentity?) -> Void
    private let linkStateChanged: (LeoAttachLinkState) -> Void
    private(set) var focusedIdentity: LeoAgentIdentity?
    /// Focused row and live attach counts for the sidebar (B-006).
    private(set) var linkState = LeoAttachLinkState.empty
    /// Per identity, ordered least -> most recently focused (or opened), so
    /// `.last` live handle is the one to bring back. Includes handles
    /// hidden in a window's live pool (B-056): attached until evicted.
    private var handlesByIdentity: [LeoAgentIdentity: [AttachmentHandle]] = [:]
    private var identityByHandle: [AttachmentHandle: LeoAgentIdentity] = [:]
    private var inactive: Set<AttachmentHandle> = []
    private var attachInProgress: Set<LeoAgentIdentity> = []
    /// B-270: agent attaches built before their host advertised dispatch
    /// placement, so without `--dispatch-placement background`: the daemon
    /// counts such a client as the default `pane` placement.
    /// `daemonFeaturesChanged` re-attaches them once it does.
    private var unplaced: Set<AttachmentHandle> = []
    /// Bumped each time a window's content area is replaced, so a request
    /// that waited on a confirmation can tell it was superseded.
    private var contentVersion: [LeoWindowID: Int] = [:]
    /// The attachment the host last reported the user viewing (behind
    /// `focusedIdentity`: attention and Jump); mapped to an identity only
    /// through `identityByHandle` (never titles or sidebar selection).
    /// Keyboard focus moving to the sidebar doesn't change it.
    private var viewedHandle: AttachmentHandle?
    /// The attachment the sidebar links to: the one with keyboard focus,
    /// except that `.focusSuspended` (app inactive) keeps the last one, so
    /// focus resuming where it was isn't a focus change (D-022).
    private var linkedHandle: AttachmentHandle?
    /// Which host focus report the link state reflects. A synchronous read
    /// of the host is newer than every report yielded so far.
    private var focusReport = 0
    private var focusReportsReceived = 0
    private var lifecycleTask: Task<Void, Never>?
    /// B-274: the window now shows this row (a navigation, never a split):
    /// its editor and browser follow. Wired by `LeoRuntime`.
    var onRowShown: (LeoWindowID, LeoRowKey) -> Void = { _, _ in }

    init(
        host: any AttachContentHost,
        executable: @escaping () throws -> String,
        remoteCommandBuilder: @escaping (LeoAgentIdentity) throws -> String = { _ in
            throw LeoDaemonError.hostUnavailable("Remote attach is not configured")
        },
        daemonFeatures: @escaping (LeoHostID) -> LeoDaemonFeatures = { _ in .none },
        report: @escaping (LeoAttachError) -> Void,
        lifecycleEventHandled: @escaping (AttachLifecycleEvent) -> Void = { _ in },
        focusedIdentityChanged: @escaping (LeoAgentIdentity?) -> Void = { _ in },
        linkStateChanged: @escaping (LeoAttachLinkState) -> Void = { _ in }
    ) {
        self.host = host
        self.executable = executable
        self.remoteCommandBuilder = remoteCommandBuilder
        self.daemonFeatures = daemonFeatures
        self.report = report
        self.lifecycleEventHandled = lifecycleEventHandled
        self.focusedIdentityChanged = focusedIdentityChanged
        self.linkStateChanged = linkStateChanged
        lifecycleTask = Task { [weak self, events = host.lifecycleEvents] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    deinit { lifecycleTask?.cancel() }

    /// The latest focus report the host has yielded, received or not.
    var latestFocusReport: Int { host.focusReportCount }

    var reusableHandleCount: Int {
        identityByHandle.keys.filter { !inactive.contains($0) }.count
    }

    /// Exposed for tests: the number of handles marked inactive (process
    /// exited) but not yet removed (closed). A handle with no identity
    /// (e.g. a plain shell) must never appear here -- see `receive(_:)`.
    var inactiveHandleCount: Int { inactive.count }

    /// Legacy entry point for existing attach callers (sidebar row click,
    /// Return, Agents ▸ Attach). Maps onto the `LeoSurfaceRequest`-based
    /// API below: `.content` is the window's content area, `.newWindow` a
    /// new window.
    func attach(identity: LeoAgentIdentity, from origin: LeoWindowID, disposition: AttachDisposition) async {
        let mapped: LeoSurfaceDisposition = switch disposition {
        case .content: .content
        case .newWindow: .window
        }
        _ = await attach(identity: identity, request: LeoSurfaceRequest(origin: origin, disposition: mapped))
    }

    /// Core attach implementation. One agent is on screen in at most one
    /// window (B-047, B-055): a content-area, start-screen or new-window
    /// request for an agent already shown brings that surface's window
    /// forward, and an untouched start screen it came from closes.
    /// Otherwise `.content` shows the agent in the window's content area
    /// (asking first if that would kill a running shell): its exited pane
    /// there is refilled in place, its hidden surface in this window's live
    /// pool is shown again (B-056), and anything else attaches anew.
    /// `.window` opens a new window; `.split` and a pane placeholder always
    /// create (tmux allows multiple attached clients). Attaching anew first
    /// lets go of the agent's surfaces hidden in any pool, so no hidden
    /// tmux client is left behind for it. `.newWindow` placement (⌘↩)
    /// sends a content-area or start-screen request to a new window; a
    /// split or pane request goes where it asked.
    func attach(
        identity: LeoAgentIdentity,
        request: LeoSurfaceRequest,
        placement: LeoAttachPlacement = .requested
    ) async -> Result<AttachmentHandle, LeoAttachError> {
        guard !attachInProgress.contains(identity) else {
            return .failure(.init(identity: identity, kind: .openFailed("Attach already in progress")))
        }
        attachInProgress.insert(identity)
        defer { attachInProgress.remove(identity) }

        let placed = placement == .newWindow && request.disposition.offersNewWindow ? request.inNewWindow : request
        discardDeadHandles(for: identity)
        if placed.disposition.focusesAgentOnScreen, let handle = focusOnScreen(identity) {
            discardStartScreen(placed.origin, jumpingTo: handle)
            return .success(handle)
        }
        let request = refillingExitedPane(of: identity, placed)
        let isHidden = request.disposition == .content && hiddenHandle(of: identity, in: request.origin) != nil
        // Showing a hidden surface needs no command; attaching anew builds
        // it before asking, so a bad executable never asks first -- and
        // again after when a hello changed placement meanwhile (B-270).
        let built = isHidden ? nil : attachCommand(for: identity)
        if case .failure(let error) = built { return .failure(error) }
        let placedWhenBuilt = placesDispatches(identity.host)
        guard await confirmReplacingContent(for: request) else {
            return .failure(.init(identity: identity, kind: .cancelled))
        }
        if isHidden, let handle = revealHidden(identity, in: request.origin) { return .success(handle) }
        let isCurrent = placesDispatches(identity.host) == placedWhenBuilt
        switch (isCurrent ? built : nil) ?? attachCommand(for: identity) {
        // A row click refilling an exited pane still shows that row (B-274).
        case .success(let command):
            return attachAnew(identity: identity, command: command, request: request, showsRow: placed.disposition.focusesAgentOnScreen)
        case .failure(let error): return .failure(error)
        }
    }

    func attachCommand(for identity: LeoAgentIdentity) -> Result<String, LeoAttachError> {
        do {
            return .success(identity.host == .local
                ? try LeoAttachCommand.build(executable: try executable(), identity: identity, features: daemonFeatures(identity.host))
                : try remoteCommandBuilder(identity))
        } catch LeoAttachCommandError.invalidAgentName {
            let attachError = LeoAttachError(identity: identity, kind: .invalidName)
            report(attachError)
            return .failure(attachError)
        } catch LeoAttachCommandError.invalidDispatchID {
            let attachError = LeoAttachError(identity: identity, kind: .invalidDispatchID)
            report(attachError)
            return .failure(attachError)
        } catch {
            let attachError = LeoAttachError(identity: identity, kind: .executable(error.localizedDescription))
            report(attachError)
            return .failure(attachError)
        }
    }

    private func attachAnew(
        identity: LeoAgentIdentity,
        command: String,
        request: LeoSurfaceRequest,
        showsRow: Bool
    ) -> Result<AttachmentHandle, LeoAttachError> {
        releaseHidden(identity)
        do {
            let workingDirectory = LeoAttachCommand.workingDirectory(identity: identity)
            let handle = try createHandle(command: command, workingDirectory: workingDirectory, request: request)
            if request.disposition == .content { contentReplaced(in: request.origin) }
            if showsRow { onRowShown(handle.windowID, .agent(identity)) }
            handlesByIdentity[identity, default: []].append(handle)
            identityByHandle[handle] = identity
            // `command` was built from placement as it is now (see `attach`).
            if identity.dispatchID == nil, !placesDispatches(identity.host) { unplaced.insert(handle) }
            adoptHostFocus()
            host.setAgentName(handle, name: identity.title ?? identity.name)
            if identity.dispatchID != nil { host.markWatchingDispatch(handle) }
            return .success(handle)
        } catch {
            let attachError = LeoAttachError(identity: identity, kind: .openFailed(error.localizedDescription))
            report(attachError)
            return .failure(attachError)
        }
    }

    /// The host may report focus on a surface it just showed before this
    /// knows about it, so read its focus now. That read is newer than every
    /// report yielded so far. A report already in flight can land after
    /// this and set `focusReport` back to its own, lower number; the fence
    /// still orders correctly because the state published then *is* that
    /// older report's, and the sidebar judges it by that number like any
    /// other report.
    private func adoptHostFocus() {
        viewedHandle = host.viewedHandle
        linkedHandle = host.focusedHandle
        focusReport = host.focusReportCount + 1
        updateFocusedIdentity()
        publishLinkState()
    }

    /// B-056: `identity`'s surface hidden in `window`'s live pool, shown
    /// again: the same surface, so no new tmux client and nothing lost.
    /// `nil` when it has none there (or the host let it go meanwhile).
    private func revealHidden(_ identity: LeoAgentIdentity, in window: LeoWindowID) -> AttachmentHandle? {
        guard let hidden = hiddenHandle(of: identity, in: window) else { return nil }
        guard host.reveal(hidden) else {
            remove(hidden)
            return nil
        }
        contentReplaced(in: window)
        moveToMostRecent(hidden, identity: identity)
        onRowShown(window, .agent(identity))
        adoptHostFocus()
        return hidden
    }

    private func hiddenHandle(of identity: LeoAgentIdentity, in window: LeoWindowID) -> AttachmentHandle? {
        handlesByIdentity[identity]?.last { !inactive.contains($0) && $0.windowID == window && !host.isShown($0) }
    }

    /// B-056: one tmux client per agent. Its surfaces hidden in any
    /// window's pool are let go before it attaches anew; the host's
    /// `.closed` for each then finds nothing left to remove.
    private func releaseHidden(_ identity: LeoAgentIdentity) {
        let hidden = (handlesByIdentity[identity] ?? []).filter { !inactive.contains($0) && !host.isShown($0) }
        for handle in hidden {
            host.release(handle)
            remove(handle)
        }
    }

    /// After an agent restart its exited pane stays on screen as a
    /// placeholder. Showing the agent in that window refills the pane in
    /// place -- the rest of a split stays as it is -- rather than
    /// replacing the whole content area (B-053, folded into B-056).
    private func refillingExitedPane(of identity: LeoAgentIdentity, _ request: LeoSurfaceRequest) -> LeoSurfaceRequest {
        guard request.disposition == .content,
              let exited = handlesByIdentity[identity]?.last(where: {
                  inactive.contains($0) && $0.windowID == request.origin && host.isShown($0)
              }) else { return request }
        return LeoSurfaceRequest(id: request.id, origin: request.origin, disposition: .placeholder(surfaceID: exited.surfaceID))
    }

    /// B-270: an agent attached before its host's hello advertised
    /// dispatch placement -- a launch-restored row races the hello -- has
    /// a client the daemon places dispatches beside as panes. Once the
    /// host advertises it, each such live attach is re-attached with the
    /// flag: one hidden in a live pool is let go, so its next show
    /// attaches anew (never a second client, D-109); one shown gets a
    /// fresh surface in its slot. Each is tried once, so a failure is
    /// reported once and leaves the old attach working. Called after every
    /// snapshot: nothing to do costs a set check.
    func daemonFeaturesChanged() {
        let due = unplaced.filter { identityByHandle[$0].map { placesDispatches($0.host) } ?? true }
        guard !due.isEmpty else { return }
        unplaced.subtract(due)
        let live = due.filter { !inactive.contains($0) && host.isOpen($0) }
        let (shown, hidden) = (live.filter(host.isShown), live.filter { !host.isShown($0) })
        for handle in hidden {
            host.releasePooledSurface(handle)
            remove(handle)
        }
        for handle in shown { reattachInPlace(handle) }
        adoptHostFocus()
    }

    private func placesDispatches(_ host: LeoHostID) -> Bool {
        daemonFeatures(host).contains(.attachDispatchPlacement)
    }

    /// The new surface takes the old one's place in the recency order; the
    /// host's `.closed` for the old one then finds nothing to remove.
    private func reattachInPlace(_ handle: AttachmentHandle) {
        guard let identity = identityByHandle[handle],
              case .success(let command) = attachCommand(for: identity) else { return }
        do {
            let workingDirectory = LeoAttachCommand.workingDirectory(identity: identity)
            let replacement = try host.reattachInPlace(handle, command: command, workingDirectory: workingDirectory)
            identityByHandle.removeValue(forKey: handle)
            identityByHandle[replacement] = identity
            handlesByIdentity[identity] = handlesByIdentity[identity]?.map { $0 == handle ? replacement : $0 }
            host.setAgentName(replacement, name: identity.title ?? identity.name)
        } catch {
            report(LeoAttachError(identity: identity, kind: .openFailed(error.localizedDescription)))
        }
    }

    /// `request`'s disposition with the default (no attach command) surface
    /// configuration -- the picker's "Plain shell" row. No identity, so no
    /// reuse and no attach bookkeeping; always creates.
    func openPlainShell(request: LeoSurfaceRequest) async -> Result<AttachmentHandle, LeoAttachError> {
        guard await confirmReplacingContent(for: request) else {
            return .failure(.init(identity: Self.plainShellIdentity, kind: .cancelled))
        }
        do {
            let handle = try createHandle(command: "", workingDirectory: nil, request: request)
            if request.disposition == .content {
                contentReplaced(in: request.origin)
                onRowShown(request.origin, .terminal(handle.surfaceID))
            }
            return .success(handle)
        } catch {
            let attachError = LeoAttachError(identity: Self.plainShellIdentity, kind: .openFailed(error.localizedDescription))
            report(attachError)
            return .failure(attachError)
        }
    }

    /// B-057 (D-111): a terminal row clicked (or Return) shows its shell in
    /// its window's content area: the same surface, hidden since it was
    /// switched away from. Already shown, it is focused. Like any row,
    /// replacing what the window shows asks first when that would close a
    /// busy shell (and a newer request replacing it meanwhile wins, D-110).
    /// The row was selected when clicked: when it isn't shown after all
    /// (the confirm cancelled, its shell let go or closed meanwhile), the
    /// sidebar selects what the window does show again.
    func showTerminal(_ handle: AttachmentHandle) async {
        guard host.isOpen(handle) else { return host.selectShownTerminal(in: handle.windowID) }
        if host.isShown(handle) {
            onRowShown(handle.windowID, .terminal(handle.surfaceID))
            return host.focus(handle)
        }
        guard await confirmReplacingContent(for: LeoSurfaceRequest(origin: handle.windowID, disposition: .content)),
              host.reveal(handle) else { return host.selectShownTerminal(in: handle.windowID) }
        contentReplaced(in: handle.windowID)
        onRowShown(handle.windowID, .terminal(handle.surfaceID))
        adoptHostFocus()
    }

    /// B-177: Split Right / Split Down on a terminal row's menu. The row
    /// shows first, as a click shows it (asking when that would close a
    /// busy shell); then `route` is handed the split beside its shell --
    /// the request ⌘D makes there. Nothing is asked for when the row isn't
    /// shown after all (the confirm cancelled, its shell gone).
    func splitTerminal(_ handle: AttachmentHandle, direction: LeoSplitDirection, route: (LeoSurfaceRequest) -> Void) async {
        await showTerminal(handle)
        guard host.isShown(handle) else { return }
        route(LeoSurfaceRequest(origin: handle.windowID, disposition: .split(direction), splitSourceSurface: handle.surfaceID))
    }

    /// B-057: the terminal row `handle` closed (⌘W once Ghostty's confirm
    /// is answered, or `exit`). Shown, the host shows its neighbour, or the
    /// start screen, in its place. Hidden -- a reveal got there first --
    /// the host lets it go and nothing on screen changes, so a request
    /// asking meanwhile isn't superseded and focus stays where it was.
    func closeTerminal(_ handle: AttachmentHandle) {
        guard host.isOpen(handle) else { return }
        let wasShown = host.isShown(handle)
        host.closeTerminal(handle)
        guard wasShown else { return }
        contentReplaced(in: handle.windowID)
        reportShownRow(in: handle.windowID)
        adoptHostFocus()
    }

    /// What `window` shows now that something on screen closed: its row,
    /// or the start screen.
    private func reportShownRow(in window: LeoWindowID) {
        onRowShown(window, host.shownHandle(in: window).map(rowKey(of:)) ?? .startScreen)
    }

    private func rowKey(of handle: AttachmentHandle) -> LeoRowKey {
        identityByHandle[handle].map(LeoRowKey.agent) ?? .terminal(handle.surfaceID)
    }

    /// Sentinel identity attached to plain-shell errors. Plain shells carry
    /// no agent identity; only `message`/`kind` are meaningful to callers.
    private static let plainShellIdentity = LeoAgentIdentity(host: .local, name: "")

    /// Only a content-area request replaces anything. The answer is about
    /// what the window showed when it asked: if another request replaced
    /// that content while this one waited, this one is dropped (a quiet
    /// cancel) -- the newer request wins, and nothing replaces content
    /// nobody confirmed replacing.
    private func confirmReplacingContent(for request: LeoSurfaceRequest) async -> Bool {
        guard request.disposition == .content else { return true }
        let version = contentVersion[request.origin, default: 0]
        guard await host.confirmReplacingContent(origin: request.origin) else { return false }
        // Its window closed meanwhile (`windowClosed`): the request goes on
        // to the host as it did before the version was pruned (which
        // reports a closed origin once the registry no longer resolves it).
        guard let now = contentVersion[request.origin] else { return true }
        return now == version
    }

    /// `window`'s content area now shows something else.
    private func contentReplaced(in window: LeoWindowID) {
        contentVersion[window, default: 0] += 1
    }

    /// `window` closed: its content version goes with it. Idempotent.
    func windowClosed(_ window: LeoWindowID) {
        contentVersion.removeValue(forKey: window)
    }

    /// The windows with a content version (tests).
    var contentVersionWindows: Set<LeoWindowID> { Set(contentVersion.keys) }

    private func createHandle(command: String, workingDirectory: String?, request: LeoSurfaceRequest) throws -> AttachmentHandle {
        switch request.disposition {
        case .content:
            return try host.showInContent(command: command, workingDirectory: workingDirectory, origin: request.origin, requestID: request.id)
        case .split(let direction):
            guard let sourceSurface = request.splitSourceSurface else {
                throw LeoAttachCoordinatorError.missingSplitSource
            }
            return try host.openSplit(
                command: command,
                workingDirectory: workingDirectory,
                origin: request.origin,
                sourceSurface: sourceSurface,
                direction: direction,
                requestID: request.id
            )
        case .window:
            return try host.openWindow(command: command, workingDirectory: workingDirectory, requestID: request.id)
        case .placeholder(let surfaceID):
            return try host.fillPlaceholder(command: command, workingDirectory: workingDirectory, origin: request.origin, surfaceID: surfaceID, requestID: request.id)
        }
    }

    private func receive(_ event: AttachLifecycleEvent) {
        defer {
            updateFocusedIdentity()
            publishLinkState()
            lifecycleEventHandled(event)
        }
        switch event {
        case .closed(let handle): remove(handle)
        case .processExited(let handle):
            // Untracked handles (e.g. a plain shell, which has no identity
            // to key attach bookkeeping on) never enter `inactive` -- there
            // is nothing for `.closed` to clean up afterwards, since
            // `remove(_:)` is itself a no-op for handles with no identity.
            guard let identity = identityByHandle[handle] else { return }
            // A dispatch's attach ends with the dispatch: nothing to
            // restart, so no placeholder; the surface closes (B-266).
            guard identity.dispatchID == nil else { return closeEndedDispatch(handle, of: identity) }
            inactive.insert(handle)
            host.rebirthPlaceholder(for: handle)
        case .focusSuspended:
            receivedFocusReport()
            viewedHandle = nil
        case .viewingChanged(let handle):
            receivedFocusReport()
            view(handle)
        case .focusChanged(let handle):
            receivedFocusReport()
            linkedHandle = handle
            // Keyboard focus on an attachment means it is viewed; focus
            // leaving for the sidebar doesn't mean it no longer is.
            if let handle { view(handle) }
        }
    }

    private func closeEndedDispatch(_ handle: AttachmentHandle, of identity: LeoAgentIdentity) {
        // A failed attach says why in a brief error, not on a lingering
        // surface; a clean exit (the dispatch closed) or a client told to
        // terminate (SIGHUP/SIGINT/SIGPIPE/SIGTERM) says nothing.
        if let exit = host.exitReport(for: handle), exit.isFailure {
            report(LeoAttachError(identity: identity, kind: .dispatchAttachFailed(code: exit.code, detail: exit.detail)))
        }
        let wasShown = host.isShown(handle)
        host.closeTerminal(handle)
        // `closeTerminal` leaves a surface hidden in a live pool: let that
        // surface (not the split tree it shares) go too, so no exited
        // dispatch lingers in a pooled split.
        if host.isOpen(handle) { host.releasePooledSurface(handle) }
        if host.isOpen(handle) {
            // Still there: keep its identity (not live) until the host's
            // `.closed` removes it, rather than strand an unknown surface.
            inactive.insert(handle)
            return
        }
        remove(handle)
        guard wasShown else { return }
        contentReplaced(in: handle.windowID)
        reportShownRow(in: handle.windowID)
        adoptHostFocus()
    }

    private func receivedFocusReport() {
        focusReportsReceived += 1
        focusReport = focusReportsReceived
    }

    private func view(_ handle: AttachmentHandle?) {
        viewedHandle = handle
        if let handle, !inactive.contains(handle), let identity = identityByHandle[handle] {
            moveToMostRecent(handle, identity: identity)
        }
    }

    /// The agent attached in the surface `surfaceID`, while that attach is
    /// live (an exited one shows a placeholder, not the agent).
    func identity(forSurface surfaceID: UUID) -> LeoAgentIdentity? {
        identityByHandle.first { $0.key.surfaceID == surfaceID && !inactive.contains($0.key) }?.value
    }

    /// Brings `identity`'s most recently focused attachment on screen
    /// forward instead of opening a duplicate. `false` when none is on
    /// screen (one hidden in a live pool isn't: `attach` shows it). An
    /// untouched start screen the request came from then closes (B-050,
    /// D-093).
    @discardableResult func focusExisting(_ identity: LeoAgentIdentity, from origin: LeoWindowID? = nil) -> Bool {
        discardDeadHandles(for: identity)
        guard let handle = focusOnScreen(identity) else { return false }
        if let origin { discardStartScreen(origin, jumpingTo: handle) }
        return true
    }

    /// A jump to an agent shown in another window leaves `origin` behind;
    /// the host closes it only if it is still an untouched start screen.
    private func discardStartScreen(_ origin: LeoWindowID, jumpingTo handle: AttachmentHandle) {
        guard handle.windowID != origin else { return }
        host.discardEmptyPlaceholder(origin: origin)
    }

    private func focusOnScreen(_ identity: LeoAgentIdentity) -> AttachmentHandle? {
        defer { publishLinkState() }
        guard let handle = handlesByIdentity[identity]?.last(where: { !inactive.contains($0) && host.isShown($0) }) else { return nil }
        onRowShown(handle.windowID, .agent(identity))
        host.focus(handle)
        moveToMostRecent(handle, identity: identity)
        return handle
    }

    private func publishLinkState() {
        // Rows count what is on screen: a surface hidden in a live pool
        // is attached but not shown, so a click shows it (via `attach`).
        let state = LeoAttachLinkState(
            focused: liveIdentity(of: linkedHandle),
            handlesByIdentity: handlesByIdentity.mapValues { $0.filter(host.isShown) },
            inactive: inactive,
            focusReport: focusReport
        )
        guard state != linkState else { return }
        linkState = state
        linkStateChanged(state)
    }

    /// An exited attachment shows a placeholder, not the agent, so it no
    /// longer counts as viewing it.
    private func updateFocusedIdentity() {
        let identity = liveIdentity(of: viewedHandle)
        guard identity != focusedIdentity else { return }
        focusedIdentity = identity
        focusedIdentityChanged(identity)
    }

    private func liveIdentity(of handle: AttachmentHandle?) -> LeoAgentIdentity? {
        handle.flatMap { inactive.contains($0) ? nil : identityByHandle[$0] }
    }

    private func discardDeadHandles(for identity: LeoAgentIdentity) {
        for handle in handlesByIdentity[identity] ?? [] where !host.isOpen(handle) { remove(handle) }
    }

    private func remove(_ handle: AttachmentHandle) {
        guard let identity = identityByHandle.removeValue(forKey: handle) else { return }
        inactive.remove(handle)
        unplaced.remove(handle)
        handlesByIdentity[identity]?.removeAll { $0 == handle }
        if handlesByIdentity[identity]?.isEmpty == true { handlesByIdentity.removeValue(forKey: identity) }
    }

    private func moveToMostRecent(_ handle: AttachmentHandle, identity: LeoAgentIdentity) {
        handlesByIdentity[identity]?.removeAll { $0 == handle }
        handlesByIdentity[identity]?.append(handle)
    }
}
