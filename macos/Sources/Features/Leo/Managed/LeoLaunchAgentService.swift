import Foundation
import ServiceManagement

/// The app's daemon LaunchAgent, `Contents/Library/LaunchAgents/<label>.plist`
/// (A4), as a seam: tests drive a scripted fake, so nothing ever registers
/// with the real launchd from a test.
protocol LeoLaunchAgentService: Sendable {
    func status() -> LeoLaunchAgentStatus
    /// Throws `LeoLaunchAgentAlreadyRegistered` for a known job, running or not.
    func register() async throws
    func unregister() async throws
    func openLoginItemsSettings()
}

/// `kSMErrorAlreadyRegistered`: says nothing about whether launchd runs the job.
struct LeoLaunchAgentAlreadyRegistered: Error, Equatable, CustomStringConvertible {
    var description: String { "Leo’s login item is already registered" }
}

struct LeoLaunchAgentRefused: Error, Equatable, CustomStringConvertible {
    var description: String { "A Debug build manages the daemon only with \(LeoFirstRun.managedDebugKey)=1" }
}

/// A job leo booted out stays down while registered, and `register()` then
/// answers "already registered": only an unregister and a register restart it.
extension LeoLaunchAgentService {
    func reRegister() async throws {
        try await unregister()
        try await register()
    }

    /// After leo stopped the app's job (`managed_stopped`): restart it and
    /// return the version hello reports.
    func restartStoppedJob(hello: LeoHelloWait) async throws -> String {
        try await reRegister()
        guard let version = await hello.version() else { throw LeoDaemonSilent() }
        return version
    }
}

struct LeoDaemonSilent: Error, Equatable, CustomStringConvertible {
    /// Points at the log instead of quoting it: the gist stays out of reach of anything private.
    static let logAdvice = "Its log, ~/.leo/state/service.log, says why."

    var description: String { "the daemon didn’t answer within \(Int(LeoManagedSetup.helloTimeout)) seconds. \(Self.logAdvice)" }
}

/// `SMAppService.agent(plistName:)`. Never call it from a test.
struct LeoSMAppLaunchAgentService: LeoLaunchAgentService {
    let label: String
    /// Whether this build may register at all (D4). A second guard behind
    /// the first-run decision, so a Debug build can't reach launchd by
    /// accident.
    let isManagementEnabled: Bool

    private var service: SMAppService { SMAppService.agent(plistName: "\(label).plist") }

    func status() -> LeoLaunchAgentStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() async throws {
        guard isManagementEnabled else { throw LeoLaunchAgentRefused() }
        do {
            try service.register()
        } catch let error as NSError where error.code == Int(kSMErrorAlreadyRegistered) {
            throw LeoLaunchAgentAlreadyRegistered()
        }
    }

    func unregister() async throws {
        guard isManagementEnabled else { throw LeoLaunchAgentRefused() }
        try await service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
