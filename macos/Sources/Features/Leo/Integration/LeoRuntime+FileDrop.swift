import AppKit

struct LeoTerminalFileDropContext: Equatable {
    let identity: LeoAgentIdentity
    let workspace: String
    /// Changes for every attachment lifetime, even when the same agent is
    /// attached again in the same surface with the same workspace.
    let attachmentGeneration: UInt64

    /// The drop target for an attachment, or nil when only Ghostty's own
    /// drop applies: a dispatch pane, which is a read-only watch (B-266),
    /// or no absolute, printable workspace.
    static func resolve(identity: LeoAgentIdentity, workspace: String?, generation: UInt64) -> Self? {
        guard identity.dispatchID == nil, let workspace, workspace.hasPrefix("/"), !workspace.contains("\0"),
              !workspace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return Self(identity: identity, workspace: workspace, attachmentGeneration: generation)
    }
}

struct LeoTerminalFileDropDependencies {
    let context: @MainActor (Ghostty.SurfaceView) -> LeoTerminalFileDropContext?
    let makeAccess: @MainActor (LeoHostID) throws -> any LeoFileAccess
    let insertText: @MainActor (Ghostty.SurfaceView, String) -> Void
}

@MainActor final class LeoTerminalFileDropQueue {
    struct Job {
        let id = UUID()
        let sources: [URL]
        let context: LeoTerminalFileDropContext
    }

    private final class Operation {
        let job: Job
        let epoch: Int
        var task: Task<Void, Never>?
        var access: (any LeoFileAccess)?

        init(job: Job, epoch: Int) {
            self.job = job
            self.epoch = epoch
        }
    }

    weak var surface: Ghostty.SurfaceView?
    private weak var runtime: LeoRuntime?
    private var jobs: [Job] = []
    private var active: Operation?
    private var epoch = 0
    private var failures: [String] = []
    private var failureContext: LeoTerminalFileDropContext?

    init(runtime: LeoRuntime, surface: Ghostty.SurfaceView) {
        self.runtime = runtime
        self.surface = surface
    }

    func enqueue(_ job: Job) {
        if let first = jobs.first?.context, first != job.context { cancel(clearStatus: true) }
        if let failureContext, failureContext != job.context { clearFailures() }
        jobs.append(job)
        startNext()
    }

    func reconcile() {
        guard let runtime, let surface else {
            cancel(clearStatus: true)
            return
        }
        let current = runtime.fileDropContext(for: surface)
        let expected = jobs.first?.context
        if expected != nil, current != expected { cancel(clearStatus: true) }
        if let failureContext, current != failureContext { clearFailures() }
        if current == nil { surface.leoFileDropTargeted = false }
    }

    func dismissError() {
        clearFailures()
    }

    func cancel(clearStatus: Bool) {
        epoch &+= 1
        jobs = []
        let operation = active
        active = nil
        operation?.task?.cancel()
        if let access = operation?.access {
            operation?.access = nil
            Task { await access.close() }
        }
        if clearStatus {
            failures = []
            failureContext = nil
            surface?.leoFileDropStatus = nil
            surface?.leoFileDropTargeted = false
        }
    }

    private func startNext() {
        guard active == nil, let job = jobs.first, let runtime, let surface else { return }
        let operation = Operation(job: job, epoch: epoch)
        active = operation
        surface.leoFileDropStatus = .uploading(job.sources.count)
        operation.task = Task { [weak self, weak runtime, weak operation] in
            guard let operation else { return }
            guard let self, let runtime else { return }
            let access: any LeoFileAccess
            do {
                try Task.checkCancellation()
                guard self.owns(operation) else { return }
                access = try runtime.makeFileDropAccess(for: job.context.identity.host)
                guard !Task.isCancelled, self.owns(operation) else {
                    await access.close()
                    return
                }
                operation.access = access
            } catch {
                guard self.owns(operation), !Task.isCancelled else { return }
                self.finish(
                    operation,
                    result: LeoFileDrop.Result(uploaded: [], failures: [
                        LeoFileDrop.Failure(name: "Upload", message: LeoRuntime.fileDropMessage(error))
                    ])
                )
                return
            }
            let result = await LeoFileDrop.upload(job.sources, to: job.context.workspace, access: access)
            await access.close()
            operation.access = nil
            guard self.owns(operation) else { return }
            self.finish(operation, result: result)
        }
    }

    private func owns(_ operation: Operation) -> Bool {
        active === operation && epoch == operation.epoch
    }

    private func finish(_ operation: Operation, result: LeoFileDrop.Result) {
        guard owns(operation), jobs.first?.id == operation.job.id else { return }
        active = nil
        jobs.removeFirst()
        guard !Task.isCancelled, let runtime, let surface,
              runtime.fileDropContext(for: surface) == operation.job.context else {
            jobs = []
            failures = []
            failureContext = nil
            surface?.leoFileDropStatus = nil
            return
        }
        // Each insertion ends with a word separator, so a later drop (queued
        // or not) never runs its first path into this one's last.
        if !result.shellText.isEmpty { runtime.insertFileDropText(result.shellText + " ", into: surface) }
        if !result.failures.isEmpty {
            failures.append(result.errorMessage)
            failureContext = operation.job.context
        }
        surface.leoFileDropStatus = failures.isEmpty ? nil : .failed(failures.joined(separator: "\n"))
        startNext()
    }

    private func clearFailures() {
        failures = []
        failureContext = nil
        if active == nil { surface?.leoFileDropStatus = nil }
    }
}

extension LeoRuntime {
    /// Reconciles in-flight drops after attach lifecycle changes. The queue
    /// implementation below owns cancellation; kept as a direct test seam so
    /// detach/reattach behavior is exercised without a live tmux client.
    func terminalFileDropContextDidChange() {
        terminalFileDropQueues.values.forEach { $0.reconcile() }
        terminalFileDropQueues = terminalFileDropQueues.filter { $0.value.surface != nil }
    }

    func cancelTerminalFileDrops() {
        terminalFileDropQueues.values.forEach { $0.cancel(clearStatus: true) }
        terminalFileDropQueues = [:]
    }

    func dismissTerminalFileDropError(from surface: Ghostty.SurfaceView) {
        terminalFileDropQueues[surface.id]?.dismissError()
        surface.leoFileDropStatus = nil
    }

    /// Whether this is a Finder file drop onto an attached agent terminal
    /// with an absolute workspace. Everything else stays with Ghostty's
    /// existing drop behavior, including plain shells.
    func acceptsFileDrop(_ pasteboard: NSPasteboard, from surface: Ghostty.SurfaceView) -> Bool {
        !pasteboard.ghosttyFileURLs.isEmpty && fileDropContext(for: surface) != nil
    }

    /// Claims and starts an agent-workspace upload. The synchronous return
    /// is AppKit's drag acceptance; completion updates the terminal overlay
    /// and inserts successful workspace paths in Finder order.
    func performFileDrop(_ pasteboard: NSPasteboard, from surface: Ghostty.SurfaceView) -> Bool {
        let sources = pasteboard.ghosttyFileURLs
        guard !sources.isEmpty, let context = fileDropContext(for: surface) else { return false }
        let queue = terminalFileDropQueues[surface.id] ?? LeoTerminalFileDropQueue(runtime: self, surface: surface)
        terminalFileDropQueues[surface.id] = queue
        queue.enqueue(.init(sources: sources, context: context))
        return true
    }

    func fileDropContext(for surface: Ghostty.SurfaceView) -> LeoTerminalFileDropContext? {
        if let dependency = terminalFileDropDependencies { return dependency.context(surface) }
        guard let identity = attachCoordinator.identity(forSurface: surface.id) else { return nil }
        return LeoTerminalFileDropContext.resolve(
            identity: identity,
            workspace: editorContext(for: identity).workspace,
            generation: attachCoordinator.generation(forSurface: surface.id) ?? 0
        )
    }

    func makeFileDropAccess(for host: LeoHostID) throws -> any LeoFileAccess {
        if let make = terminalFileDropDependencies?.makeAccess { return try make(host) }
        return try hostSelection.makeFileAccess(for: host)
    }

    func insertFileDropText(_ text: String, into surface: Ghostty.SurfaceView) {
        if let insert = terminalFileDropDependencies?.insertText {
            insert(surface, text)
        } else {
            surface.surfaceModel?.sendText(text)
        }
    }

    static func fileDropMessage(_ error: Error) -> String {
        if let error = error as? LeoFileAccessError { return error.localizedDescription }
        return LeoSFTPServerText.sanitized(error.localizedDescription)
    }
}
