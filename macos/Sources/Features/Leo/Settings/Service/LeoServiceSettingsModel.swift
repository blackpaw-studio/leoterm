import AppKit
import Combine
import Foundation
import LeoKit

/// The Service tab: the daemon's status, Restart Daemon, Restart All Agents,
/// Reload Config and a polled tail of its log.
///
/// A restart drops the app's own connection, so after the daemon accepts it
/// the model polls the status until the process is a new one (a new pid or
/// start time), riding out the connection being down. The machine reconnects
/// through its registry as usual and hands the model its new client
/// (`reload(using:)`), which the polling then uses. The pane stays mounted
/// meanwhile. The daemon allows one restart at a time, so a second request
/// answers 409 `restart_in_progress`; that is shown as a restart under way,
/// not a failure.
@MainActor final class LeoServiceSettingsModel: ObservableObject, LeoSettingsPane {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// A question waiting on the user. The alert's buttons take the value they
    /// were shown with: SwiftUI has cleared `confirmation` before they run.
    enum Confirmation: Equatable {
        case restartDaemon
        /// How many agents are running now, when the status is known.
        case restartAgents(running: Int?)
    }

    static let logLines = 200
    static let logInterval = Duration.seconds(2)
    static let restartPollInterval = Duration.seconds(1)
    static let defaultMaxRestartPolls = 60

    @Published private(set) var phase = Phase.loading
    @Published private(set) var status: LeoServiceStatus?
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var isRestarting = false
    @Published private(set) var isWorking = false
    @Published private(set) var notice: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var agentsSummary: String?
    @Published private(set) var logText = ""
    @Published private(set) var logError: String?
    @Published private(set) var isLogPaused = false
    @Published private(set) var isLogVisible = false

    private var client: any LeoConfigClient
    private let machine: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let copyToPasteboard: (String) -> Void
    private let maxRestartPolls: Int
    private var restartTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?

    init(
        client: any LeoConfigClient, machine: String,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        copyToPasteboard: @escaping (String) -> Void = LeoServiceSettingsModel.writeToGeneralPasteboard,
        maxRestartPolls: Int = LeoServiceSettingsModel.defaultMaxRestartPolls
    ) {
        self.client = client
        self.machine = machine
        self.sleep = sleep
        self.copyToPasteboard = copyToPasteboard
        self.maxRestartPolls = maxRestartPolls
    }

    deinit {
        restartTask?.cancel()
        logTask?.cancel()
    }

    nonisolated static func writeToGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: LeoSettingsPane

    /// Nothing here is a draft.
    var hasUnsavedChanges: Bool { false }
    func discardChanges() {}

    /// The pane stays on screen through the reconnect a restart causes.
    var staysMountedWhileReconnecting: Bool { isRestarting }

    /// The machine reconnected: the status and the polling go through its new client.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        await refreshStatus()
    }

    // MARK: Status

    /// Reads the status. Coming back to a pane that is already showing one
    /// refreshes it in place, and a failure then leaves what was shown.
    func load() async {
        let wasLoaded = phase == .loaded
        if !wasLoaded { phase = .loading }
        do {
            status = try await client.serviceStatus()
            phase = .loaded
        } catch where !wasLoaded {
            phase = .failed(Self.message(for: error))
        } catch {}
    }

    /// Reads the status again; a failure leaves what was shown.
    func refreshStatus() async {
        if let current = try? await client.serviceStatus() {
            status = current
            if phase != .loaded { phase = .loaded }
        }
    }

    var canRestartDaemon: Bool { !isRestarting && !isWorking }
    var canRestartAgents: Bool { !isRestarting && !isWorking }

    // MARK: Confirmations

    func requestRestartDaemon() {
        guard canRestartDaemon else { return }
        confirmation = .restartDaemon
    }

    func requestRestartAgents() {
        guard canRestartAgents else { return }
        confirmation = .restartAgents(running: status?.runningAgentCount)
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    /// Takes the confirmation the alert showed.
    func confirm(_ pending: Confirmation) async {
        confirmation = nil
        switch pending {
        case .restartDaemon: await restartDaemon()
        case .restartAgents: await restartAllAgents()
        }
    }

    func dismissMessages() {
        notice = nil
        errorMessage = nil
        agentsSummary = nil
    }

    // MARK: Restart daemon

    /// Asks the daemon to restart, then waits for it to come back as a new
    /// process. Answers why it couldn't start one, or nil; a restart that is
    /// already running counts as started. The caller has confirmed.
    @discardableResult
    func restartDaemon() async -> String? {
        guard canRestartDaemon else { return nil }
        isWorking = true
        defer { isWorking = false }
        dismissMessages()
        if status == nil { await refreshStatus() }
        let before = status
        do {
            _ = try await client.restartService()
            beginWaiting(previous: before)
            return nil
        } catch where LeoServiceError.isRestartInProgress(error) {
            notice = "A restart is already in progress on \(machine)."
            beginWaiting(previous: before)
            return nil
        } catch {
            let message = Self.message(for: error)
            errorMessage = message
            return message
        }
    }

    private func beginWaiting(previous: LeoServiceStatus?) {
        isRestarting = true
        restartTask?.cancel()
        restartTask = Task { [weak self] in await self?.waitForRestart(previous: previous) }
    }

    /// Polls until the daemon is a new process. Errors are expected while it
    /// is down. Without a status from before the restart, "new" means it was
    /// seen down and then up.
    private func waitForRestart(previous: LeoServiceStatus?) async {
        var sawDown = false
        for _ in 0..<maxRestartPolls {
            do { try await sleep(Self.restartPollInterval) } catch { return }
            do {
                let current = try await client.serviceStatus()
                status = current
                guard previous.map(current.isRestarted(since:)) ?? sawDown else { continue }
                isRestarting = false
                notice = "leo restarted on \(machine)."
                return
            } catch {
                sawDown = true
            }
        }
        isRestarting = false
        errorMessage = "leo on \(machine) hasn’t come back yet. Check its connection under Machines."
    }

    /// Waits for the restart wait to end.
    func settledRestart() async {
        await restartTask?.value
    }

    // MARK: Restart agents, reload

    /// Restarts every agent. Answers why it didn't fully work, or nil.
    @discardableResult
    func restartAllAgents() async -> String? {
        guard canRestartAgents else { return nil }
        isWorking = true
        defer { isWorking = false }
        dismissMessages()
        do {
            let result = try await client.restartAgents()
            agentsSummary = Self.summary(of: result)
            await refreshStatus()
            return Self.failureText(of: result)
        } catch {
            let message = Self.message(for: error)
            errorMessage = message
            return message
        }
    }

    func reloadConfig() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        dismissMessages()
        do {
            let reload = try await client.reloadConfig()
            if let warning = reload.warning { errorMessage = warning } else { notice = "Configuration reloaded on \(machine)." }
            await refreshStatus()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func summary(of result: LeoAgentsRestartResult) -> String {
        let count = result.restarted.count
        var parts = ["Restarted \(count) agent\(count == 1 ? "" : "s")."]
        if !result.skipped.isEmpty { parts.append("\(result.skipped.count) skipped.") }
        if let failure = failureText(of: result) { parts.append(failure) }
        return parts.joined(separator: " ")
    }

    static func failureText(of result: LeoAgentsRestartResult) -> String? {
        guard result.hasFailures else { return nil }
        return "Couldn’t restart " + result.failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "."
    }

    // MARK: Log tail

    func setLogVisible(_ visible: Bool) {
        isLogVisible = visible
        updateLogPolling()
    }

    func setLogPaused(_ paused: Bool) {
        isLogPaused = paused
        updateLogPolling()
    }

    func copyLog() {
        copyToPasteboard(logText)
    }

    /// Ends every loop: the pane is gone or the machine changed.
    func stop() {
        isLogVisible = false
        updateLogPolling()
        restartTask?.cancel()
        restartTask = nil
        isRestarting = false
    }

    private func updateLogPolling() {
        guard isLogVisible, !isLogPaused else {
            logTask?.cancel()
            logTask = nil
            return
        }
        guard logTask == nil else { return }
        logTask = Task { [weak self] in await self?.pollLog() }
    }

    private func pollLog() async {
        while !Task.isCancelled {
            await fetchLog()
            do { try await sleep(Self.logInterval) } catch { return }
        }
    }

    private func fetchLog() async {
        do {
            let log = try await client.serviceLog(lines: Self.logLines)
            guard !Task.isCancelled else { return }
            if log.text != logText { logText = log.text }
            logError = nil
        } catch {
            guard !Task.isCancelled else { return }
            logError = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
