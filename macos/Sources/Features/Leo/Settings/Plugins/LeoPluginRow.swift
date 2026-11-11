import Foundation
import LeoKit

/// One plugin as the Settings list shows it. Built from the manager's
/// `LeoPluginInfo`; holds only display text and flags, so the view stays dumb.
struct LeoPluginRow: Equatable, Identifiable {
    enum Status: Equatable {
        case running
        /// The user's switch is off.
        case off
        /// Asks for more than was approved; `lines` are the added permissions.
        case needsApproval(lines: [String])
        case restarting(reason: String)
        /// Turned off after repeated crashes; offers Re-enable.
        case crashDisabled(reason: String)
        case refused(reason: String)
    }

    let id: String
    let name: String
    let version: String
    /// First seven characters of the pinned commit; nil for bundled and dev plugins.
    let shortSHA: String?
    /// "Built in", "github.com/owner/repo", or the dev folder's path.
    let sourceText: String
    let isDev: Bool
    let isBundled: Bool
    /// What the plugin may do, as the user approved it.
    let permissionsSummary: String
    let status: Status
    let isEnabled: Bool
    let hiddenSections: [String]

    var canUninstall: Bool { !isBundled }

    private var needsApproval: Bool {
        if case .needsApproval = status { true } else { false }
    }

    /// A plugin waiting for approval isn't running whatever its saved switch
    /// says, so the switch reads off until the person approves.
    var switchIsOn: Bool { isEnabled && !needsApproval }
    /// Approval is the way back on (Review…), not the switch.
    var canToggle: Bool { !needsApproval }
    /// Dev folders are the author's own: uninstalling forgets them but leaves the folder.
    var uninstallDetail: String {
        isDev ? "The folder stays where it is." : "Its folder moves to the Trash and its Keychain items are deleted."
    }

    init(_ info: LeoPluginInfo) {
        id = info.id
        name = info.name
        version = info.version
        isEnabled = info.isEnabled
        hiddenSections = info.hiddenSections
        permissionsSummary = Self.summary(of: info.approvedPermissions)
        switch info.source {
        case .bundled:
            shortSHA = nil
            sourceText = "Built in"
            isDev = false
            isBundled = true
        case .git(let url, _, let sha):
            shortSHA = String(sha.prefix(Self.shortSHALength))
            sourceText = Self.displayURL(url)
            isDev = false
            isBundled = false
        case .dev(let path):
            shortSHA = nil
            sourceText = (path as NSString).abbreviatingWithTildeInPath
            isDev = true
            isBundled = false
        }
        status = Self.status(of: info)
    }

    // MARK: Private

    private static let shortSHALength = 7

    private static func status(of info: LeoPluginInfo) -> Status {
        switch info.state {
        case .running: .running
        case .stoppedByUser: .off
        case .needsApproval: .needsApproval(lines: LeoPluginApprovalRequest(reviewing: info)?.permissionLines ?? [])
        case .restarting(let reason): .restarting(reason: reason)
        case .disabled(let reason): .crashDisabled(reason: reason)
        case .refused(let reason): .refused(reason: reason)
        }
    }

    static func summary(of permissions: LeoPluginPermissions) -> String {
        var parts: [String] = []
        if !permissions.network.isEmpty { parts.append("Network: \(permissions.network.joined(separator: ", "))") }
        if permissions.secrets { parts.append("Keychain") }
        if !permissions.agents.isEmpty { parts.append("Agents: \(permissions.agents.map(\.rawValue).joined(separator: ", "))") }
        return parts.isEmpty ? "No special access" : parts.joined(separator: " · ")
    }

    /// `https://github.com/owner/repo.git` → `github.com/owner/repo`.
    private static func displayURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host else { return raw }
        var path = components.path
        if path.hasSuffix(".git") { path.removeLast(".git".count) }
        return host + path
    }
}
