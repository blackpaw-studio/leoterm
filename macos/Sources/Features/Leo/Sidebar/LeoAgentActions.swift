import Combine
import Foundation

@MainActor final class LeoAgentActions: ObservableObject {
    @Published private(set) var pendingActions: Set<LeoAgentRow.ID> = []
    /// Bound to whatever connection is currently selected -- updated by
    /// `LeoRuntime` (via `updateDaemon`) each time `LeoHostSelection`
    /// reports a new connected socket. Every call below is unscoped
    /// (no `host:` parameter): the daemon instance itself already
    /// represents "whichever host is currently connected".
    private var daemon: any LeoDaemonClient
    let hostSelection: LeoHostSelection
    private let cli: LeoCLI
    private let model: LeoSidebarModel
    private let refresh: () -> Void
    var cliForSpawn: LeoCLI { cli }
    private let clock: @Sendable () -> Date
    private let processRunner: any LeoProcessRunning
    private let sshExecutable: String
    private var cachedTemplates: [LeoHostID: (value: [LeoTemplate], fetchedAt: Date)] = [:]

    init(daemon: any LeoDaemonClient, cli: LeoCLI, model: LeoSidebarModel,
         hostSelection: LeoHostSelection? = nil,
         processRunner: any LeoProcessRunning = LeoProcessRunner(),
         sshExecutable: String = "/usr/bin/ssh",
         refresh: @escaping () -> Void, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.daemon = daemon
        self.cli = cli
        self.model = model
        self.hostSelection = hostSelection ?? LeoHostSelection(store: LeoHostStore(defaults: .standard), defaults: .standard)
        self.processRunner = processRunner
        self.sshExecutable = sshExecutable
        self.refresh = refresh
        self.clock = clock
    }

    /// Called by `LeoRuntime` whenever the selected connection's daemon
    /// changes (a new host's tunnel came up, or we switched back to
    /// localhost).
    func updateDaemon(_ daemon: any LeoDaemonClient) {
        self.daemon = daemon
    }

    func start(_ row: LeoAgentRow) { run(row) { daemon in try await daemon.start(row.name) } }
    func stop(_ row: LeoAgentRow) { run(row) { daemon in try await daemon.stop(row.name, wakeOnMessage: nil) } }
    func restart(_ row: LeoAgentRow) { run(row) { daemon in _ = try await daemon.restart(row.name) } }
    func setTemplate(_ row: LeoAgentRow, template: String) { run(row) { daemon in try await daemon.setTemplate(row.name, template: template) } }
    func rename(_ row: LeoAgentRow, newName: String) { run(row) { daemon in _ = try await daemon.rename(row.name, newName: newName) } }
    func delete(_ row: LeoAgentRow, force: Bool, deleteBranch: Bool, success: @escaping () -> Void = {}) {
        run(
            row, onSuccess: { (_: Void) in success() },
            operation: { daemon in try await daemon.delete(row.name, force: force, deleteBranch: deleteBranch) }
        )
    }
    func deletePlan(_ row: LeoAgentRow, receive: @escaping (LeoDeletePlan) -> Void) {
        run(row, refreshOnSuccess: false, onSuccess: receive) { daemon in try await daemon.deletePlan(row.name) }
    }

    /// Local templates come from the CLI (unchanged); a remote host's
    /// templates are fetched via a one-off `ssh ... leo template list --json`
    /// exec (not the persistent tunnel socket), matching how the local CLI
    /// path itself works.
    func templates() async throws -> [LeoTemplate] {
        let host = hostSelection.selected
        if let cached = cachedTemplates[host], clock().timeIntervalSince(cached.fetchedAt) < 60 {
            return cached.value
        }
        let value: [LeoTemplate]
        if host == .local {
            value = try await cli.templateList()
        } else if let configuration = hostSelection.selectedConfiguration {
            value = try await fetchRemoteTemplates(configuration: configuration)
        } else {
            throw LeoDaemonError.hostUnavailable("Remote host is not configured")
        }
        cachedTemplates[host] = (value, clock())
        return value
    }

    private func fetchRemoteTemplates(configuration: LeoHostConfiguration) async throws -> [LeoTemplate] {
        let arguments = try LeoSSHCommand(configuration: configuration).execArguments(
            remoteCommand: [configuration.remoteLeoPath, "template", "list", "--json"]
        )
        let result = try await processRunner.run(executable: sshExecutable, arguments: arguments, timeout: 30)
        guard result.status == 0 else {
            throw LeoDaemonError.transport(String(data: result.stderr, encoding: .utf8) ?? "ssh exited \(result.status)")
        }
        do {
            return try JSONDecoder().decode([LeoTemplate].self, from: result.stdout)
        } catch {
            throw LeoDaemonError.decoding(String(describing: error))
        }
    }

    func spawn(_ request: LeoSpawnRequest, attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
               dismiss: @escaping () -> Void, failure: @escaping (String) -> Void) {
        let capturedDaemon = daemon
        let host = hostSelection.selected
        let capturedGeneration = hostSelection.generationToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let agent = try await capturedDaemon.spawn(request)
                guard self.hostSelection.generationToken == capturedGeneration else { return }
                dismiss(); refresh()
                attach(LeoAgentRow(host: host, name: agent.name, template: agent.template, status: agent.status ?? .unknown("unknown"), activity: .unknown, actionDetail: nil), .reuseOrTab)
            } catch {
                guard self.hostSelection.generationToken == capturedGeneration else { return }
                failure(Self.message(error))
            }
        }
    }

    func setRowError(_ message: String, for row: LeoAgentRow) {
        model.setRowError(message, for: row.id)
    }

    /// Captures `daemon` and the selection's `generationToken` synchronously
    /// at invocation time (not when the operation actually runs), and runs
    /// `operation` against that captured daemon -- so a mid-flight host
    /// switch can never redirect an already-issued request to the NEW
    /// connection's socket. `operation`'s return value is ONLY handed to
    /// `onSuccess` (and `refresh()` only called) after re-checking the
    /// token: every UI callback -- refresh, row-error, and whatever
    /// `onSuccess` does (attach, delete-plan display, etc.) -- is gated,
    /// never invoked from inside `operation` itself where a stale
    /// completion could still reach it.
    private func run<T>(_ row: LeoAgentRow, refreshOnSuccess: Bool = true, onSuccess: @escaping (T) -> Void = { (_: T) in },
                        operation: @escaping @MainActor (any LeoDaemonClient) async throws -> T) {
        guard pendingActions.insert(row.id).inserted else { return }
        let capturedDaemon = daemon
        let capturedGeneration = hostSelection.generationToken
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingActions.remove(row.id) }
            do {
                let value = try await operation(capturedDaemon)
                guard self.hostSelection.generationToken == capturedGeneration else { return }
                if refreshOnSuccess { self.refresh() }
                onSuccess(value)
            } catch {
                guard self.hostSelection.generationToken == capturedGeneration else { return }
                self.model.setRowError(Self.message(error), code: Self.code(error), for: row.id)
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if case let LeoDaemonError.daemon(_, message, _) = error { return message }
        return error.localizedDescription
    }

    private static func code(_ error: Error) -> String? {
        if case let LeoDaemonError.daemon(code, _, _) = error { return code }
        return nil
    }
}
