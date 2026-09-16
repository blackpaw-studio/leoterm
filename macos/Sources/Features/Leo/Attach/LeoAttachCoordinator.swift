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
    private var handlesByIdentity: [LeoAgentIdentity: [AttachmentHandle]] = [:]
    private var identityByHandle: [AttachmentHandle: LeoAgentIdentity] = [:]
    private var inactive: Set<AttachmentHandle> = []
    private var attachInProgress: Set<LeoAgentIdentity> = []
    private var lifecycleTask: Task<Void, Never>?

    init(
        host: any AttachTabHost,
        executable: @escaping () throws -> String,
        remoteCommandBuilder: @escaping (LeoAgentIdentity) throws -> String = { _ in
            throw LeoDaemonError.hostUnavailable("Remote attach is not configured")
        },
        report: @escaping (LeoAttachError) -> Void,
        lifecycleEventHandled: @escaping (AttachLifecycleEvent) -> Void = { _ in }
    ) {
        self.host = host
        self.executable = executable
        self.remoteCommandBuilder = remoteCommandBuilder
        self.report = report
        self.lifecycleEventHandled = lifecycleEventHandled
        lifecycleTask = Task { [weak self, events = host.lifecycleEvents] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    deinit { lifecycleTask?.cancel() }

    var reusableHandleCount: Int {
        identityByHandle.keys.filter { !inactive.contains($0) }.count
    }

    /// Exposed for tests: the number of handles marked inactive (process
    /// exited) but not yet removed (closed). A handle with no identity
    /// (e.g. a plain shell) must never appear here -- see `receive(_:)`.
    var inactiveHandleCount: Int { inactive.count }

    /// Legacy entry point for existing attach callers (sidebar row click,
    /// CLI-driven attach). Maps onto the `LeoSurfaceRequest`-based API below;
    /// `.reuseOrTab` becomes `.tab` (reuse-eligible), `.newWindow` becomes
    /// `.window` (always creates).
    func attach(identity: LeoAgentIdentity, from origin: LeoWindowID, disposition: AttachDisposition) async {
        let mapped: LeoSurfaceDisposition = disposition == .reuseOrTab ? .tab : .window
        _ = await attach(identity: identity, request: LeoSurfaceRequest(origin: origin, disposition: mapped))
    }

    /// Core attach implementation. Only `.tab` reuses a live handle for
    /// `identity` -- `.split`, `.window`, and `.placeholder` always create a
    /// new destination (tmux allows multiple attached clients).
    func attach(identity: LeoAgentIdentity, request: LeoSurfaceRequest) async -> Result<AttachmentHandle, LeoAttachError> {
        guard !attachInProgress.contains(identity) else {
            return .failure(.init(identity: identity, kind: .openFailed("Attach already in progress")))
        }
        attachInProgress.insert(identity)
        defer { attachInProgress.remove(identity) }

        discardDeadHandles(for: identity)
        if request.disposition == .tab,
           let handle = handlesByIdentity[identity]?.last(where: { !inactive.contains($0) }) {
            host.focus(handle)
            moveToMostRecent(handle, identity: identity)
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
            host.setTitleSeed(handle, title: "\(identity.name) · \(identity.host.displayName)")
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
            return try host.openTab(command: command, workingDirectory: workingDirectory, from: request.origin)
        case .split(let direction):
            guard let sourceSurface = request.splitSourceSurface else {
                throw LeoAttachCoordinatorError.missingSplitSource
            }
            return try host.openSplit(
                command: command,
                workingDirectory: workingDirectory,
                origin: request.origin,
                sourceSurface: sourceSurface,
                direction: direction
            )
        case .window:
            return try host.openWindow(command: command, workingDirectory: workingDirectory)
        case .placeholder:
            return try host.fillPlaceholder(command: command, workingDirectory: workingDirectory, origin: request.origin)
        }
    }

    private func receive(_ event: AttachLifecycleEvent) {
        defer { lifecycleEventHandled(event) }
        switch event {
        case .closed(let handle): remove(handle)
        case .processExited(let handle):
            // Untracked handles (e.g. a plain shell, which has no identity
            // to key attach bookkeeping on) never enter `inactive` -- there
            // is nothing for `.closed` to clean up afterwards, since
            // `remove(_:)` is itself a no-op for handles with no identity.
            guard identityByHandle[handle] != nil else { return }
            inactive.insert(handle)
        case .titleChanged(let handle, let title):
            guard !title.isEmpty, identityByHandle[handle] != nil else { return }
            host.setTitleSeed(handle, title: nil)
        }
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
