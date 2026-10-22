import Foundation

/// One line of a Test Connection result, in the order they run.
enum LeoConnectionTestStep: CaseIterable, Sendable {
    case ssh
    case daemon
    case machineStats

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .daemon: "Daemon"
        case .machineStats: "Machine stats"
        }
    }
}

enum LeoConnectionTestOutcome: Equatable, Sendable {
    case passed(String)
    case failed(String)
    /// Worked, but the machine can't offer it (a daemon too old for stats).
    case unavailable(String)
    /// Skipped because an earlier step failed.
    case notTested
}

/// What Test Connection found for one machine configuration.
struct LeoConnectionTestReport: Equatable, Sendable {
    let outcomes: [LeoConnectionTestStep: LeoConnectionTestOutcome]
    let duration: TimeInterval

    func outcome(for step: LeoConnectionTestStep) -> LeoConnectionTestOutcome {
        outcomes[step] ?? .notTested
    }

    /// The machine is usable once ssh and the daemon both answered. Stats
    /// are optional: an older daemon simply has none.
    var succeeded: Bool {
        guard case .passed = outcome(for: .ssh), case .passed = outcome(for: .daemon) else { return false }
        return true
    }

    static func sshFailed(_ detail: String, duration: TimeInterval = 0) -> LeoConnectionTestReport {
        LeoConnectionTestReport(outcomes: [.ssh: .failed(detail)], duration: duration)
    }

    static func daemonFailed(sshDetail: String, detail: String, duration: TimeInterval = 0) -> LeoConnectionTestReport {
        LeoConnectionTestReport(outcomes: [.ssh: .passed(sshDetail), .daemon: .failed(detail)], duration: duration)
    }

    static func success(
        version: String, statsAdvertised: Bool, sshDetail: String = "Reachable", duration: TimeInterval = 0
    ) -> LeoConnectionTestReport {
        LeoConnectionTestReport(
            outcomes: [
                .ssh: .passed(sshDetail),
                .daemon: .passed("leo \(version) answered"),
                .machineStats: statsAdvertised
                    ? .passed("Available (machine_stats)")
                    : .unavailable("Not offered by this daemon (needs leo 0.57 or newer)"),
            ],
            duration: duration
        )
    }
}

/// Runs Test Connection. The app's tester uses a throwaway connection that
/// never touches a live one; tests script the report.
protocol LeoMachineConnectionTesting: Sendable {
    func test(_ configuration: LeoHostConfiguration) async -> LeoConnectionTestReport
}
