import Foundation

struct LeoAttachError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case executable(String)
        case invalidName
        case openFailed(String)
    }

    let identity: LeoAgentIdentity
    let kind: Kind

    var message: String {
        switch kind {
        case .executable(let message), .openFailed(let message): message
        case .invalidName: "Agent names cannot contain NUL or newline characters"
        }
    }
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
    private let host: any AttachTabHost
    private let executable: () throws -> String
    /// Builds the shell command for a *remote* identity (an app-owned SSH
    /// attach via `LeoSSHCommand.attachShellCommand`). Local identities
    /// always go through `LeoAttachCommand.build(executable:identity:)`.
    private let remoteCommandBuilder: (LeoAgentIdentity) throws -> String
    private let report: (LeoAttachError) -> Void
    private let lifecycleEventHandled: (AttachLifecycleEvent) -> Void
    private let focusedIdentityChanged: (LeoAgentIdentity?) -> Void
    private let linkStateChanged: (LeoAttachLinkState) -> Void
    private(set) var focusedIdentity: LeoAgentIdentity?
    /// Focused row and live attach counts for the sidebar (B-006).
    private(set) var linkState = LeoAttachLinkState.empty
    /// Per identity, ordered least -> most recently focused (or opened), so
    /// `.last` live handle is the one to bring back.
    private var handlesByIdentity: [LeoAgentIdentity: [AttachmentHandle]] = [:]
    private var identityByHandle: [AttachmentHandle: LeoAgentIdentity] = [:]
    private var inactive: Set<AttachmentHandle> = []
    private var attachInProgress: Set<LeoAgentIdentity> = []
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

    init(
        host: any AttachTabHost,
        executable: @escaping () throws -> String,
        remoteCommandBuilder: @escaping (LeoAgentIdentity) throws -> String = { _ in
            throw LeoDaemonError.hostUnavailable("Remote attach is not configured")
        },
        report: @escaping (LeoAttachError) -> Void,
        lifecycleEventHandled: @escaping (AttachLifecycleEvent) -> Void = { _ in },
        focusedIdentityChanged: @escaping (LeoAgentIdentity?) -> Void = { _ in },
        linkStateChanged: @escaping (LeoAttachLinkState) -> Void = { _ in }
    ) {
        self.host = host
        self.executable = executable
        self.remoteCommandBuilder = remoteCommandBuilder
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
    /// CLI-driven attach). Maps onto the `LeoSurfaceRequest`-based API below;
    /// `.reuseOrTab` becomes `.tab` (reuse-eligible), `.newTab` a `.tab`
    /// that always creates (⌘-click), `.newWindow` becomes `.window`
    /// (always creates).
    func attach(identity: LeoAgentIdentity, from origin: LeoWindowID, disposition: AttachDisposition) async {
        let (mapped, reuse): (LeoSurfaceDisposition, LeoAttachReuse) = switch disposition {
        case .reuseOrTab: (.tab, .focusExisting)
        case .newTab: (.tab, .alwaysNew)
        case .newWindow: (.window, .alwaysNew)
        }
        _ = await attach(identity: identity, request: LeoSurfaceRequest(origin: origin, disposition: mapped), reuse: reuse)
    }

    /// Core attach implementation. One tab per agent (B-047): a `.tab` or
    /// start-screen request goes to `identity`'s most recently used live
    /// attachment when it has one, unless `reuse` is `.alwaysNew`; the start
    /// screen it came from is then closed. `.split`, `.window`, and a pane
    /// placeholder always create a new destination (tmux allows multiple
    /// attached clients).
    func attach(
        identity: LeoAgentIdentity,
        request: LeoSurfaceRequest,
        reuse: LeoAttachReuse = .focusExisting
    ) async -> Result<AttachmentHandle, LeoAttachError> {
        guard !attachInProgress.contains(identity) else {
            return .failure(.init(identity: identity, kind: .openFailed("Attach already in progress")))
        }
        attachInProgress.insert(identity)
        defer { attachInProgress.remove(identity) }

        if reuse == .focusExisting, request.disposition.reusesOpenTab, let handle = focusMostRecent(identity) {
            if request.disposition != .tab { host.discardEmptyPlaceholder(origin: request.origin) }
            return .success(handle)
        }

        let command: String
        do {
            command = identity.host == .local
                ? try LeoAttachCommand.build(executable: try executable(), identity: identity)
                : try remoteCommandBuilder(identity)
        } catch LeoAttachCommandError.invalidAgentName {
            let attachError = LeoAttachError(identity: identity, kind: .invalidName)
            report(attachError)
            return .failure(attachError)
        } catch {
            let attachError = LeoAttachError(identity: identity, kind: .executable(error.localizedDescription))
            report(attachError)
            return .failure(attachError)
        }

        do {
            let workingDirectory = LeoAttachCommand.workingDirectory(identity: identity)
            let handle = try createHandle(command: command, workingDirectory: workingDirectory, request: request)
            handlesByIdentity[identity, default: []].append(handle)
            identityByHandle[handle] = identity
            // The host may report focus on the new surface before it is
            // registered here.
            viewedHandle = host.viewedHandle
            linkedHandle = host.focusedHandle
            // Newer than every report yielded so far. A report already in
            // flight can land after this and set `focusReport` back to its
            // own, lower number; the fence still orders correctly because
            // the state published then *is* that older report's, and the
            // sidebar judges it by that number like any other report.
            focusReport = host.focusReportCount + 1
            updateFocusedIdentity()
            publishLinkState()
            host.setAgentName(handle, name: identity.name)
            return .success(handle)
        } catch {
            let attachError = LeoAttachError(identity: identity, kind: .openFailed(error.localizedDescription))
            report(attachError)
            return .failure(attachError)
        }
    }

    /// `request`'s disposition with the default (no attach command) surface
    /// configuration -- the picker's "Plain shell" row. No identity, so no
    /// reuse and no attach bookkeeping; always creates.
    func openPlainShell(request: LeoSurfaceRequest) async -> Result<AttachmentHandle, LeoAttachError> {
        do {
            let handle = try createHandle(command: "", workingDirectory: nil, request: request)
            return .success(handle)
        } catch {
            let attachError = LeoAttachError(identity: Self.plainShellIdentity, kind: .openFailed(error.localizedDescription))
            report(attachError)
            return .failure(attachError)
        }
    }

    /// Sentinel identity attached to plain-shell errors. Plain shells carry
    /// no agent identity; only `message`/`kind` are meaningful to callers.
    private static let plainShellIdentity = LeoAgentIdentity(host: .local, name: "")

    private func createHandle(command: String, workingDirectory: String?, request: LeoSurfaceRequest) throws -> AttachmentHandle {
        switch request.disposition {
        case .tab:
            return try host.openTab(command: command, workingDirectory: workingDirectory, from: request.origin, requestID: request.id)
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
            guard identityByHandle[handle] != nil else { return }
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

    /// Brings `identity`'s most recently focused live attachment forward
    /// instead of opening a duplicate. `false` when it has none.
    @discardableResult func focusExisting(_ identity: LeoAgentIdentity) -> Bool {
        focusMostRecent(identity) != nil
    }

    private func focusMostRecent(_ identity: LeoAgentIdentity) -> AttachmentHandle? {
        discardDeadHandles(for: identity)
        defer { publishLinkState() }
        guard let handle = handlesByIdentity[identity]?.last(where: { !inactive.contains($0) }) else { return nil }
        host.focus(handle)
        moveToMostRecent(handle, identity: identity)
        return handle
    }

    private func publishLinkState() {
        let state = LeoAttachLinkState(
            focused: liveIdentity(of: linkedHandle),
            handlesByIdentity: handlesByIdentity,
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
        handlesByIdentity[identity]?.removeAll { $0 == handle }
        if handlesByIdentity[identity]?.isEmpty == true { handlesByIdentity.removeValue(forKey: identity) }
    }

    private func moveToMostRecent(_ handle: AttachmentHandle, identity: LeoAgentIdentity) {
        handlesByIdentity[identity]?.removeAll { $0 == handle }
        handlesByIdentity[identity]?.append(handle)
    }
}
