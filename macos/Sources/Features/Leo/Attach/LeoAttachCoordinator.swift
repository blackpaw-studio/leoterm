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

@MainActor final class LeoAttachCoordinator {
    private let host: any AttachTabHost
    private let executable: () throws -> String
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
        report: @escaping (LeoAttachError) -> Void,
        lifecycleEventHandled: @escaping (AttachLifecycleEvent) -> Void = { _ in }
    ) {
        self.host = host
        self.executable = executable
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

    func attach(identity: LeoAgentIdentity, from origin: LeoWindowID, disposition: AttachDisposition) async {
        guard !attachInProgress.contains(identity) else { return }
        attachInProgress.insert(identity)
        defer { attachInProgress.remove(identity) }

        discardDeadHandles(for: identity)
        if disposition == .reuseOrTab,
           let handle = handlesByIdentity[identity]?.last(where: { !inactive.contains($0) }) {
            host.focus(handle)
            moveToMostRecent(handle, identity: identity)
            return
        }

        do {
            let command: String
            do {
                command = try LeoAttachCommand.build(executable: try executable(), identity: identity)
            } catch LeoAttachCommandError.invalidAgentName {
                report(.init(identity: identity, kind: .invalidName))
                return
            } catch {
                report(.init(identity: identity, kind: .executable(error.localizedDescription)))
                return
            }
            let workingDirectory = LeoAttachCommand.workingDirectory(identity: identity)
            let handle = try disposition == .newWindow
                ? host.openWindow(command: command, workingDirectory: workingDirectory)
                : host.openTab(command: command, workingDirectory: workingDirectory, from: origin)
            handlesByIdentity[identity, default: []].append(handle)
            identityByHandle[handle] = identity
            host.setTitleSeed(handle, title: "\(identity.name) · \(identity.host.displayName)")
        } catch {
            report(.init(identity: identity, kind: .openFailed(error.localizedDescription)))
        }
    }

    private func receive(_ event: AttachLifecycleEvent) {
        defer { lifecycleEventHandled(event) }
        switch event {
        case .closed(let handle): remove(handle)
        case .processExited(let handle): inactive.insert(handle)
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
