import Combine
import Foundation
import LeoKit

@MainActor final class LeoAgentActions: ObservableObject {
    @Published private(set) var pendingActions: Set<LeoAgentRow.ID> = []
    /// What a failed spawn or start says in place of the daemon's raw
    /// `claude_not_found` text, which names its PATH. The local install flow
    /// is only for the local host: a remote one needs claude installed there.
    static func claudeMissingMessage(on host: LeoHostID) -> String {
        guard host != .local else { return "Claude Code isn’t installed. Set it up from Agents ▸ Set Up Claude…" }
        return "Claude Code isn’t installed on \(host.displayName). Install it there, then try again."
    }
    private static let claudeNotFoundCode = "claude_not_found"
    /// A spawn or start on the local host failed with `claude_not_found`: the onboarding offer.
    var claudeNotFound: () -> Void = {}
    /// Each machine's templates, for every UI reader (New Agent sheet, a
    /// row's Set Template submenu), keyed by host so one machine's list is
    /// never shown for another (B-054) and loading one never blanks
    /// another's. Filled by `loadTemplates(for:)` when a machine connects.
    @Published private(set) var templateLists: [LeoHostID: LeoTemplateListState] = [:]
    /// B-283: each machine's environment names and template defaults,
    /// reloaded whenever its connection comes up (so it describes the host
    /// it talks to, tunnel included) and on a manual refresh. An older
    /// daemon fails quietly: every reader is gated on `agent_environments`.
    @Published private(set) var environmentCatalogs: [LeoHostID: LeoEnvironmentCatalogState] = [:]
    private var environmentCatalogTokens: [LeoHostID: Int] = [:]
    /// Resolves the daemon, generation and configuration of the row's own
    /// host for every call below, so actions on one machine never wait on,
    /// or get redirected by, another's connection.
    private let clients: any LeoMachineClientResolving
    /// Only for views still following the one selection (the sidebar, the
    /// spawn sheet) until the runtime moves to the machine registry; no
    /// action reads it.
    let hostSelection: LeoHostSelection
    private let cli: LeoCLI
    private let model: LeoSidebarModel
    private let refresh: () -> Void
    /// Runs a remote host's one-off `ssh … leo template list --json`
    /// (B-061). Deliberately no default (B-112): `LeoRuntime` passes its
    /// `templateFetchRunner`, and a test that forgot a fake would ssh into a
    /// real host on connecting it.
    private let processRunner: any LeoProcessRunning
    private let sshExecutable: String
    /// One slot per host -- `templateLists` and the Agents-menu submenu both
    /// read through `templates(for:)` below, never fetching on their own.
    /// Templates are host *configuration*, not agent state, so this is
    /// deliberately NOT invalidated by every (now SSE-driven, frequent)
    /// sidebar list refresh -- only by a user-initiated sidebar refresh
    /// (`invalidateTemplateCache`, called by `LeoRuntime` off the feed's
    /// `onManualRefresh` hook) and `LeoTemplateCache.templateCacheTTL` as a
    /// backstop.
    private let templateCache = LeoTemplateCache()
    /// A token per host bumped by every reload so a fetch that lands after a
    /// newer one started is dropped.
    private var templateListTokens: [LeoHostID: Int] = [:]

    init(clients: any LeoMachineClientResolving, cli: LeoCLI, model: LeoSidebarModel,
         hostSelection: LeoHostSelection,
         processRunner: any LeoProcessRunning,
         sshExecutable: String = "/usr/bin/ssh",
         refresh: @escaping () -> Void) {
        self.clients = clients
        self.cli = cli
        self.model = model
        self.hostSelection = hostSelection
        self.processRunner = processRunner
        self.sshExecutable = sshExecutable
        self.refresh = refresh
    }

    func templateList(for host: LeoHostID) -> LeoTemplateListState { templateLists[host] ?? .loading }

    func environmentCatalog(for host: LeoHostID) -> LeoEnvironmentCatalogState { environmentCatalogs[host] ?? .loading }

    /// Called by `LeoRuntime` whenever `host`'s connection comes up or is
    /// replaced: loads that machine's templates and environment catalog,
    /// leaving every other machine's untouched.
    func hostConnected(_ host: LeoHostID) {
        loadTemplates(for: host)
        reloadEnvironmentCatalog(for: host)
    }

    /// Fetches `host`'s catalog from the daemon it is bound to now; a load
    /// that lands after a newer one started is dropped. Nothing happens
    /// while the host has no daemon.
    func reloadEnvironmentCatalog(for host: LeoHostID) {
        guard let daemon = clients.daemon(for: host) else { return }
        let token = environmentCatalogTokens[host, default: 0] + 1
        environmentCatalogTokens[host] = token
        Task { [weak self] in
            let state: LeoEnvironmentCatalogState
            do {
                state = .loaded(try await daemon.environmentCatalog())
            } catch {
                state = .failed(Self.message(error))
            }
            guard let self, token == self.environmentCatalogTokens[host] else { return }
            self.environmentCatalogs[host] = state
        }
    }

    /// Prefetches `host`'s template list so a menu has it on its first open.
    /// A host that has no loaded list yet shows `.loading` meanwhile;
    /// reloading a loaded one (a reconnect) keeps its list showing.
    func loadTemplates(for host: LeoHostID) {
        if !(templateLists[host]?.isLoaded ?? false) { templateLists[host] = .loading }
        let token = nextTemplateListToken(for: host)
        Task { [weak self] in await self?.reloadTemplateList(for: host, token: token) }
    }

    /// Called by `LeoRuntime` when the user explicitly asks the sidebar to
    /// refresh (never for SSE-triggered or periodic-poll refreshes), so a
    /// template renamed/added/removed on a daemon is reflected on demand
    /// without every row or the Agents menu fetching for themselves. Reloads
    /// every machine already loaded.
    func invalidateTemplateCache() {
        let templateCache = templateCache
        let hosts = Set(templateLists.keys)
        let tokens = hosts.map { ($0, nextTemplateListToken(for: $0)) }
        Task { [weak self] in
            await templateCache.invalidate()
            for (host, token) in tokens { await self?.reloadTemplateList(for: host, token: token) }
        }
        environmentCatalogs.keys.forEach { reloadEnvironmentCatalog(for: $0) }
    }

    private func nextTemplateListToken(for host: LeoHostID) -> Int {
        let token = templateListTokens[host, default: 0] + 1
        templateListTokens[host] = token
        return token
    }

    /// Publishes `host`'s templates unless a newer reload for it started
    /// meanwhile.
    private func reloadTemplateList(for host: LeoHostID, token: Int) async {
        guard token == templateListTokens[host] else { return }
        let state: LeoTemplateListState
        do {
            state = .loaded(try await templates(for: host))
        } catch {
            state = .failed(Self.message(error))
        }
        guard token == templateListTokens[host] else { return }
        templateLists[host] = state
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
    /// B-283: replaces the agent's environment override (empty clears it);
    /// the daemon restarts and resumes it. A refusal shows on the row.
    func setEnvironments(_ row: LeoAgentRow, names: [String]) {
        run(row) { daemon in try await daemon.setEnvironments(row.name, names: names) }
    }
    func rename(_ row: LeoAgentRow, newName: String) { run(row) { daemon in _ = try await daemon.rename(row.name, newName: newName) } }
    /// B-274: closes `row`'s editor panes in every window before it's
    /// deleted, asking about unsaved edits; `false` on Cancel. Wired by
    /// `LeoRuntime`.
    var closePanes: @MainActor (LeoAgentRow) async -> Bool = { _ in true }

    /// Asks about the agent's unsaved panes first (`closePanes`): Cancel
    /// leaves the agent alone.
    func delete(_ row: LeoAgentRow, force: Bool, deleteBranch: Bool, success: @escaping () -> Void = {}) {
        Task { [weak self] in
            guard let self, await closePanes(row) else { return }
            run(
                row, onSuccess: { (_: Void) in success() },
                operation: { daemon in try await daemon.delete(row.name, force: force, deleteBranch: deleteBranch) }
            )
        }
    }
    func deletePlan(_ row: LeoAgentRow, receive: @escaping (LeoDeletePlan) -> Void) {
        run(row, refreshOnSuccess: false, onSuccess: receive) { daemon in try await daemon.deletePlan(row.name) }
    }

    /// Local templates come from the CLI (unchanged); a remote host's
    /// templates are fetched via a one-off `ssh ... leo template list --json`
    /// exec (not the persistent tunnel socket), matching how the local CLI
    /// path itself works. Cached per host.
    func templates(for host: LeoHostID) async throws -> [LeoTemplate] {
        let configuration = clients.configuration(for: host)
        return try await templateCache.refreshIfStale(for: host) { [cli, processRunner, sshExecutable] in
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

    /// Spawns on `host`'s own connection: refused, without a request, while
    /// that machine has none (still connecting, failed or disabled). A result
    /// that lands after `host` reconnected is not attached, but `failure`
    /// still tells the sheet, which would otherwise stay spawning. Another
    /// machine's connection changing never affects it.
    func spawn(_ request: LeoSpawnRequest, on host: LeoHostID,
               attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
               dismiss: @escaping () -> Void, failure: @escaping (String) -> Void) {
        guard let daemon = clients.daemon(for: host) else {
            failure("Not connected to \(host.displayName) yet")
            return
        }
        let capturedGeneration = clients.generation(for: host)
        Task { [weak self] in
            guard let self else { return }
            do {
                let agent = try await daemon.spawn(request)
                guard self.clients.generation(for: host) == capturedGeneration else {
                    failure("Host changed; the agent may have been created on \(host.displayName)")
                    return
                }
                dismiss(); refresh()
                attach(LeoAgentRow(host: host, name: agent.name, template: agent.template, status: agent.status ?? .unknown("unknown"), activity: .unknown, actionDetail: nil, wakeOnMessage: agent.wakeOnMessage), .content)
            } catch {
                failure(Self.message(error, host: host))
                self.offerOnboardingIfClaudeMissing(error, host: host)
            }
        }
    }

    func setRowError(_ message: String, for row: LeoAgentRow) {
        model.setRowError(message, for: row.id)
    }

    /// Captures the row's host's daemon and generation synchronously at
    /// invocation time (not when the operation actually runs), and runs
    /// `operation` against that captured daemon -- so a mid-flight reconnect
    /// can never redirect an already-issued request to the NEW connection's
    /// socket. `operation`'s return value is ONLY handed to `onSuccess` (and
    /// `refresh()` only called) after re-checking the generation: every UI
    /// callback -- refresh, row-error, and whatever `onSuccess` does (attach,
    /// delete-plan display, etc.) -- is gated, never invoked from inside
    /// `operation` itself where a stale completion could still reach it.
    /// Only the row's own host counts: another machine reconnecting changes
    /// nothing here. A row whose host has no connection fails on the row
    /// without a request.
    private func run<T>(_ row: LeoAgentRow, refreshOnSuccess: Bool = true, onSuccess: @escaping (T) -> Void = { (_: T) in },
                        onFailure: @escaping () -> Void = {},
                        operation: @escaping @MainActor (any LeoDaemonClient) async throws -> T) {
        guard pendingActions.insert(row.id).inserted else { return }
        guard let capturedDaemon = clients.daemon(for: row.host) else {
            pendingActions.remove(row.id)
            model.setRowError("\(row.host.displayName) isn't connected.", for: row.id)
            onFailure()
            return
        }
        let capturedGeneration = clients.generation(for: row.host)
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingActions.remove(row.id) }
            do {
                let value = try await operation(capturedDaemon)
                guard self.clients.generation(for: row.host) == capturedGeneration else { return }
                if refreshOnSuccess { self.refresh() }
                onSuccess(value)
            } catch {
                guard self.clients.generation(for: row.host) == capturedGeneration else { return }
                self.model.setRowError(Self.message(error, host: row.host), code: Self.code(error), for: row.id)
                self.offerOnboardingIfClaudeMissing(error, host: row.host)
                onFailure()
            }
        }
    }

    private func offerOnboardingIfClaudeMissing(_ error: Error, host: LeoHostID) {
        if host == .local, Self.code(error) == Self.claudeNotFoundCode { claudeNotFound() }
    }

    private static func message(_ error: Error, host: LeoHostID) -> String {
        code(error) == claudeNotFoundCode ? claudeMissingMessage(on: host) : message(error)
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
