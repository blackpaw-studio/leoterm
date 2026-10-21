import Foundation
import ServiceManagement

/// The app's daemon LaunchAgent, `Contents/Library/LaunchAgents/<label>.plist`
/// (A4), as a seam: tests drive a scripted fake, so nothing ever registers
/// with the real launchd from a test.
protocol LeoLaunchAgentService: Sendable {
    func status() -> LeoLaunchAgentStatus
    /// Idempotent: an agent that is already registered is not an error.
    func register() async throws
    func unregister() async throws
    func openLoginItemsSettings()
}

struct LeoLaunchAgentRefused: Error, Equatable, CustomStringConvertible {
    var description: String { "A Debug build manages the daemon only with \(LeoFirstRun.managedDebugKey)=1" }
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
            return
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
