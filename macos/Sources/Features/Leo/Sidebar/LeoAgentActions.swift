import Combine
import Foundation

@MainActor final class LeoAgentActions: ObservableObject {
    @Published private(set) var pendingActions: Set<LeoAgentRow.ID> = []
    /// The selected host's templates, for every UI reader (New Agent sheet,
    /// a row's Set Template submenu): prefetched on each host selection so
    /// a menu has them on its first open, and reset to `.loading` the
    /// moment the host changes so the old host's list is never shown for
    /// the new one (B-054).
    @Published private(set) var templateList: LeoTemplateListState = .loading
    /// Bound to whatever connection is currently selected -- updated by
    /// `LeoRuntime` (via `updateDaemon`) each time `LeoHostSelection`
    /// reports a new connected socket. Every call below is unscoped
    /// (no `host:` parameter): the daemon instance itself already
    /// represents "whichever host is currently connected".
    private var daemon: any LeoDaemonClient
    /// The host `daemon` actually talks to. `LeoHostSelection.selected`
    /// moves the moment a host is picked, but `daemon` only once that
    /// host's tunnel is up (and never, if it fails), so a spawn checks this,
    /// not the selection (B-176).
    private var daemonHost: LeoHostID
    /// The one selection `LeoRuntime` owns, injected: only its tunnel may
    /// exist, so a second `LeoHostSelection` (and a second tunnel for the
    /// same host) is never built here (B-027).
    let hostSelection: LeoHostSelection
    private let cli: LeoCLI
    private let model: LeoSidebarModel
    private let refresh: () -> Void
    /// Runs a remote host's one-off `ssh … leo template list --json`
    /// (B-061). Deliberately no default (B-112): `LeoRuntime` passes its
    /// `templateFetchRunner`, and a test that forgot a fake would ssh into a
    /// real host on selecting it.
    private let processRunner: any LeoProcessRunning
    private let sshExecutable: String
    /// One cache instance for whichever host is currently selected --
    /// `templateList` and the Agents-menu submenu both read through
    /// `templates()` below, never fetching on their own. Templates are host
    /// *configuration*, not agent state, so this is deliberately NOT
    /// invalidated by every (now SSE-driven, frequent) sidebar list
    /// refresh -- only by: the selected host changing (keyed inside the
    /// cache actor by `refreshIfStale(for:_:)`, so the switch is atomic
    /// with the read), a user-initiated sidebar refresh
    /// (`invalidateTemplateCache`, called by `LeoRuntime` off the feed's
    /// `onManualRefresh` hook), and `LeoTemplateCache.templateCacheTTL` as
    /// a backstop.
    private let templateCache = LeoTemplateCache()
    /// The host `templateList` describes, and a token bumped by every
    /// reload so a fetch that lands after a newer one started is dropped.
    private var templateListHost: LeoHostID?
    private var templateListToken = 0
    private var selectionObservation: AnyCancellable?

    init(daemon: any LeoDaemonClient, daemonHost: LeoHostID = .local, cli: LeoCLI, model: LeoSidebarModel,
         hostSelection: LeoHostSelection,
         processRunner: any LeoProcessRunning,
         sshExecutable: String = "/usr/bin/ssh",
         refresh: @escaping () -> Void) {
        self.daemon = daemon
        self.daemonHost = daemonHost
        self.cli = cli
        self.model = model
        self.hostSelection = hostSelection
        self.processRunner = processRunner
        self.sshExecutable = sshExecutable
        self.refresh = refresh
        // `dropFirst`: the list loads on the first `select()` (which
        // `LeoHostSelection.start` always makes, once hosts are loaded),
        // not at construction, before a remote host's configuration exists.
        selectionObservation = hostSelection.$selected.dropFirst().sink { [weak self] host in
            self?.hostSelected(host)
        }
    }

    /// Called by `LeoRuntime` whenever the selected connection's daemon
    /// changes (a new host's tunnel came up, or we switched back to
    /// localhost).
    func updateDaemon(_ daemon: any LeoDaemonClient, host: LeoHostID) {
        self.daemon = daemon
        daemonHost = host
    }

    /// Called by `LeoRuntime` when the user explicitly asks the sidebar to
    /// refresh (never for SSE-triggered or periodic-poll refreshes), so a
    /// template renamed/added/removed on the daemon side is reflected on
    /// demand without every row or the Agents menu fetching for themselves.
    func invalidateTemplateCache() {
        let templateCache = templateCache
        let token = nextTemplateListToken()
        Task { [weak self] in
            await templateCache.invalidate()
            await self?.reloadTemplateList(token: token)
        }
    }

    /// `$selected` publishes before the new value is stored, so the
    /// reload is deferred to a task, which reads the stored selection.
    /// The old host's list (or a failure) is cleared synchronously, here;
    /// re-selecting the same host (a retry) keeps its loaded list showing.
    private func hostSelected(_ host: LeoHostID) {
        if host != templateListHost || !templateList.isLoaded {
            templateListHost = host
            templateList = .loading
        }
        let token = nextTemplateListToken()
        Task { [weak self] in await self?.reloadTemplateList(token: token) }
    }

    private func nextTemplateListToken() -> Int {
        templateListToken += 1
        return templateListToken
    }

    /// Publishes the selected host's templates unless a newer reload (a
    /// later host switch or manual refresh) started meanwhile.
    private func reloadTemplateList(token: Int) async {
        guard token == templateListToken else { return }
        let state: LeoTemplateListState
        do {
            state = .loaded(try await templates())
        } catch {
            state = .failed(Self.message(error))
        }
        guard token == templateListToken else { return }
        templateList = state
    }

    /// `completion` says whether the daemon accepted the start; a refusal
    /// also shows on the row. Neither is called when a start for the row
    /// is already in flight or the host changed meanwhile.
    func start(_ row: LeoAgentRow, completion: @escaping (Bool) -> Void = { _ in }) {
        run(
            row, onSuccess: { (_: Void) in completion(true) }, onFailure: { completion(false) },
            operation: { daemon in try await daemon.start(row.name) }
        )
    }
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
        return try await templateCache.refreshIfStale(for: host) { [cli, processRunner, sshExecutable, host, configuration = hostSelection.selectedConfiguration] in
            if host == .local {
                return try await cli.templateList()
            } else if let configuration {
                return try await Self.fetchRemoteTemplates(configuration: configuration, processRunner: processRunner, sshExecutable: sshExecutable)
            } else {
                throw LeoDaemonError.hostUnavailable("Remote host is not configured")
            }
        }
    }

    private static func fetchRemoteTemplates(
        configuration: LeoHostConfiguration, processRunner: any LeoProcessRunning, sshExecutable: String
    ) async throws -> [LeoTemplate] {
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

    /// Spawns on `expectedHost` only: refused, without a request, while the
    /// daemon is still bound to another host (a tunnel still connecting, or
    /// one that failed). A result that lands after the selection moved on
    /// is not attached, but `failure` still tells the sheet, which would
    /// otherwise stay spawning.
    func spawn(_ request: LeoSpawnRequest, on expectedHost: LeoHostID,
               attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
               dismiss: @escaping () -> Void, failure: @escaping (String) -> Void) {
        guard daemonHost == expectedHost else {
            failure("Not connected to \(expectedHost.displayName) yet")
            return
        }
        let capturedDaemon = daemon
        let host = daemonHost
        let capturedGeneration = hostSelection.generationToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let agent = try await capturedDaemon.spawn(request)
                guard self.hostSelection.generationToken == capturedGeneration else {
                    failure("Host changed; the agent may have been created on \(host.displayName)")
                    return
                }
                dismiss(); refresh()
                attach(LeoAgentRow(host: host, name: agent.name, template: agent.template, status: agent.status ?? .unknown("unknown"), activity: .unknown, actionDetail: nil, wakeOnMessage: agent.wakeOnMessage), .content)
            } catch {
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
                        onFailure: @escaping () -> Void = {},
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
                onFailure()
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
