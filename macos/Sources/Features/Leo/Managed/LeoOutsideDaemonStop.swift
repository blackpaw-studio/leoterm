import Foundation

/// Sends `SIGTERM`, as a seam: tests record it instead.
protocol LeoProcessSignalling: Sendable {
    func terminate(pid: Int32) throws
}

struct LeoSignalError: Error, Equatable, CustomStringConvertible {
    let pid: Int32
    let code: Int32

    var description: String { "kill(\(pid), SIGTERM): \(String(cString: strerror(code)))" }
}

struct LeoPOSIXSignaller: LeoProcessSignalling {
    /// Never a process group, launchd or this app, whatever a caller passes.
    func terminate(pid: Int32) throws {
        guard pid > 1, pid != getpid() else { throw LeoSignalError(pid: pid, code: EINVAL) }
        guard kill(pid, SIGTERM) == 0 else { throw LeoSignalError(pid: pid, code: errno) }
    }
}

/// B10: a leo daemon answers on the socket while the app's job isn't
/// loaded (`restart` says `not_registered`): started by hand, or left over.
/// After the user confirms, stop exactly the pid `/health` reported, checked
/// again right before the signal, wait for it to go, then start the app's
/// job and wait for hello. SIGTERM is leo's clean shutdown: agents' tmux
/// sessions keep running.
struct LeoOutsideDaemonStop: Sendable {
    enum Outcome: Equatable, Sendable {
        case managed(version: String)
        case awaitingApproval
        /// `/health` no longer confirms the pid: nothing was signalled.
        case changed(pid: Int32?)
        /// Still answering after `stopTimeout`; nothing was started.
        case didNotStop(pid: Int32)
        case signalFailed(String)
        /// Stopped, but the app's job didn't start or answer.
        case failed(String)
    }

    static let stopTimeout: TimeInterval = 30
    static let pollInterval: TimeInterval = 0.5

    let agent: any LeoLaunchAgentService
    let probe: any LeoDaemonProbing
    let signaller: any LeoProcessSignalling
    let clock: any LeoDaemonClock

    func run(pid: Int32) async -> Outcome {
        switch await probe.health() {
        case .answered(_, let current) where current == pid:
            do {
                try signaller.terminate(pid: pid)
            } catch {
                return .signalFailed("\(error)")
            }
            guard await waitUntilGone(pid) else { return .didNotStop(pid: pid) }
        case .answered(_, let current):
            return .changed(pid: current)
        case .unresponsive:
            return .changed(pid: nil)
        case .absent:
            break
        }
        return await startAppJob()
    }

    /// Gone once nothing answers, or another daemon (the app's) does.
    private func waitUntilGone(_ pid: Int32) async -> Bool {
        let deadline = clock.now() + Self.nanoseconds(Self.stopTimeout)
        while true {
            switch await probe.health() {
            case .absent: return true
            case .answered(_, let current) where current != pid: return true
            case .answered, .unresponsive: break
            }
            let now = clock.now()
            guard now < deadline else { return false }
            do {
                try await clock.sleep(until: min(now + Self.nanoseconds(Self.pollInterval), deadline))
            } catch {
                return false
            }
        }
    }

    /// `not_registered` means launchd has no job loaded for the app's label.
    private func startAppJob() async -> Outcome {
        do {
            switch agent.status() {
            case .requiresApproval: return .awaitingApproval
            case .enabled: try await agent.reRegister()
            case .notRegistered, .notFound: try await agent.register()
            }
        } catch {
            return .failed("Leo couldn’t start its daemon: \(error)")
        }
        guard let version = await LeoHelloWait(probe: probe, clock: clock).version() else {
            return .failed("Leo’s daemon didn’t answer after starting: \(LeoDaemonSilent())")
        }
        return .managed(version: version)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}
