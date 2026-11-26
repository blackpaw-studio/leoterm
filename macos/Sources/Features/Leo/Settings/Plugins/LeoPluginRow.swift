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
    /// The branch or tag a git plugin follows ("Default branch" when none was given); nil for bundled and dev plugins.
    let refText: String?
    /// The stored ref as typed (empty for the default branch); nil for bundled and dev plugins.
    let ref: String?
    /// "Built in", "github.com/owner/repo", or the dev folder's path.
    let sourceText: String
    let isDev: Bool
    let isBundled: Bool
    /// A git source that is not Blackpaw Studio's; the row says so.
    let isUnverified: Bool
    /// What the plugin may do, as the user approved it.
    let permissionsSummary: String
    let status: Status
    let isEnabled: Bool
    let hiddenSections: [String]
    /// The plugin's agent pane and whether it is shown; nil for a plugin with none.
    let pane: Pane?
    /// Accounts the user picked for the plugin, each removable.
    let accounts: [Account]

    struct Account: Equatable, Identifiable {
        let id: String
        /// "Codex · This Mac · ~/.codex", or "API key · Work · api.deepseek.com".
        let title: String
    }

    /// A remote path stays absolute: this Mac's home says nothing about that machine's.
    /// An API key shows its name and the one host it is sent to, never the key.
    static func accountTitle(_ grant: LeoPluginCredentialGrant, home: String, approved: LeoPluginPermissions) -> String {
        switch grant.subject {
        case .account(let kind, let path):
            let machine = grant.isRemote ? grant.machine.displayName : "This Mac"
            let shown = grant.isRemote ? path : LeoPluginCredentialPath.abbreviate(path, home: home)
            return "\(kind.displayName) · \(machine) · \(shown)"
        case .apiKey(let provider, let name):
            guard let host = approved.apiKeys.first(where: { $0.provider == provider })?.host else { return "API key · \(name)" }
            return "API key · \(name) · \(host)"
        }
    }

    struct Pane: Equatable {
        let id: String
        let isShown: Bool
    }

    var canUninstall: Bool { !isBundled }
    /// Only git installs follow a branch or tag.
    var canChangeRef: Bool { !isBundled && !isDev }

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
        pane = info.manifest?.contributes.panes.first.map { Pane(id: $0.id, isShown: !info.hiddenPanes.contains($0.id)) }
        permissionsSummary = Self.summary(of: info.approvedPermissions)
        accounts = info.credentialGrants.map { grant in
            Account(id: grant.id, title: Self.accountTitle(grant, home: NSHomeDirectory(), approved: info.approvedPermissions))
        }
        isUnverified = LeoPluginSourceTrust.classify(info.source) == .unverified
        switch info.source {
        case .bundled:
            shortSHA = nil
            ref = nil
            refText = nil
            sourceText = "Built in"
            isDev = false
            isBundled = true
        case .git(let url, let storedRef, let sha):
            ref = storedRef == Self.defaultRef ? "" : storedRef
            refText = Self.refText(storedRef)
            shortSHA = String(sha.prefix(Self.shortSHALength))
            sourceText = Self.displayURL(url)
            isDev = false
            isBundled = false
        case .dev(let path):
            shortSHA = nil
            ref = nil
            refText = nil
            sourceText = (path as NSString).abbreviatingWithTildeInPath
            isDev = true
            isBundled = false
        }
        status = Self.status(of: info)
    }

    // MARK: Private

    private static let shortSHALength = 7
    private static let defaultRef = "HEAD"

    /// A ref for people: the installer stores an empty ref as `HEAD`.
    static func refText(_ ref: String) -> String {
        let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == defaultRef ? "the default branch" : "“\(name)”"
    }

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
        if !permissions.credentials.isEmpty { parts.append("Accounts: \(permissions.credentials.map(\.displayName).joined(separator: ", "))") }
        if !permissions.apiKeys.isEmpty { parts.append("API keys: \(permissions.apiKeys.map(\.label).joined(separator: ", "))") }
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
