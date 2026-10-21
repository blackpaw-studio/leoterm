import Foundation

/// What `hello` on `~/.leo/state/leo.sock` said. The socket is authoritative.
enum LeoDaemonProbeResult: Equatable, Sendable {
    case live(version: String)
    /// No socket, or nothing listening on it.
    case absent
    /// Something holds the socket but didn't answer in time.
    case unresponsive
}

/// `SMAppService.Status` for the app's daemon agent.
enum LeoLaunchAgentStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    /// SMAppService has no record of the label. macOS 26.6 says this for a
    /// bundled agent that was never registered, so only the plist file
    /// (`LeoFirstRunInputs.hasBundledAgentPlist`) says the bundle is incomplete.
    case notFound
}

/// A leo install outside the app, detected in contract order (the first match wins).
enum LeoExistingInstall: Equatable, Sendable {
    case live
    case installedStopped
    case binaryOnly
    case none
}

/// The one-time takeover offer's remembered answer.
enum LeoTakeoverAnswer: String, Equatable, Sendable {
    case notAsked
    case declined
    /// Handover said `no_launchd_job`: the live daemon wasn't started by launchd.
    case unavailable
}

struct LeoFirstRunInputs: Equatable, Sendable {
    var location: LeoAppLocation
    var probe: LeoDaemonProbeResult
    var marker: LeoMarkerState
    var existing: LeoExistingInstall
    var agentStatus: LeoLaunchAgentStatus
    var takeover: LeoTakeoverAnswer
    var buildKind: LeoBuildKind
    var managedDebug: Bool
    var hasBundledHelpers: Bool
    /// `Contents/Library/LaunchAgents/<label>.plist` is on disk. macOS 26.6
    /// answers `.notFound` for a bundled agent that was never registered, so
    /// the file, not the status, says whether the bundle is complete.
    var hasBundledAgentPlist: Bool
    /// leo's `<CLI plist>.handed-over` backup exists: `--to-app` ran.
    var hasHandedOverBackup: Bool
}

enum LeoRepairReason: Equatable, Sendable {
    case invalidMarker(String)
    /// The bundle lacks `Contents/Helpers/leo` or its LaunchAgent plist.
    case bundleIncomplete
}

enum LeoFirstRunAction: Equatable, Sendable {
    case blockMove(isManaged: Bool)
    case useLive(offerTakeover: Bool)
    case install
    case ensureManaged(refreshLink: Bool, register: Bool)
    case awaitApproval
    case repair(LeoRepairReason)
    case recoverOrphanRegistration
    /// Crashed between `handover --to-app` and the marker write: leo's
    /// markerless `--to-cli`, after unregistering a registered app job.
    case restoreHandedOverCLI(unregisterFirst: Bool)
    /// The same state, but a daemon answers: touch nothing.
    case leaveHandedOverAlone
    case observeOnly
}

/// B1: what the app does with the daemon at launch. Pure: B5 gathers the
/// inputs (without touching SMAppService in a Debug build) and executes.
enum LeoFirstRun {
    /// Debug builds manage nothing unless the developer opts in (D4): they
    /// share `~/.leo` with the production daemon.
    static let managedDebugKey = "LEO_MANAGED_DEBUG"

    static func isManagementEnabled(buildKind: LeoBuildKind, environment: [String: String]) -> Bool {
        buildKind == .release || environment[managedDebugKey] == "1"
    }

    static func decide(_ inputs: LeoFirstRunInputs) -> LeoFirstRunAction {
        guard inputs.buildKind == .release || inputs.managedDebug else { return .observeOnly }
        if case .foreign = inputs.marker { return .observeOnly }
        // Crashed between `handover --to-app` and the marker write: the CLI
        // plist is still leo's backup, so no daemon starts at login. Wherever
        // the app is, the bundled leo can restore it.
        if inputs.marker == .absent, inputs.hasHandedOverBackup, inputs.hasBundledHelpers {
            if case .live = inputs.probe { return .leaveHandedOverAlone }
            let isRegistered = inputs.agentStatus == .enabled || inputs.agentStatus == .requiresApproval
            return .restoreHandedOverCLI(unregisterFirst: isRegistered)
        }
        if case .needsMove = inputs.location { return .blockMove(isManaged: inputs.marker.isOurs) }
        // Release to CLI crashed between its handover and `unregister()`.
        if inputs.marker == .absent, inputs.agentStatus == .enabled || inputs.agentStatus == .requiresApproval {
            return .recoverOrphanRegistration
        }
        let isBundleComplete = inputs.hasBundledHelpers && inputs.hasBundledAgentPlist
        switch inputs.marker {
        case .absent:
            return isBundleComplete ? decideUnmanaged(inputs) : .observeOnly
        case .invalid(let reason):
            return .repair(isBundleComplete ? .invalidMarker(reason) : .bundleIncomplete)
        case .ours:
            guard isBundleComplete else { return .repair(.bundleIncomplete) }
            // A Debug opt-in never repoints the link the Release app owns.
            let refreshLink = inputs.location == .inApplications
            switch inputs.agentStatus {
            case .requiresApproval: return .awaitApproval
            case .enabled: return .ensureManaged(refreshLink: refreshLink, register: false)
            // `.notFound` with the plist present is just "never registered".
            case .notRegistered, .notFound: return .ensureManaged(refreshLink: refreshLink, register: true)
            }
        case .foreign:
            return .observeOnly
        }
    }

    private static func decideUnmanaged(_ inputs: LeoFirstRunInputs) -> LeoFirstRunAction {
        // Something holds the socket: installing would fight it for the daemon lock.
        if inputs.probe == .unresponsive { return .useLive(offerTakeover: false) }
        switch inputs.existing {
        case .live:
            return .useLive(offerTakeover: inputs.takeover == .notAsked)
        case .installedStopped:
            // `no_launchd_job` was about a daemon that has since stopped;
            // handover supports a stopped CLI install with its plist.
            return .useLive(offerTakeover: inputs.takeover != .declined)
        case .binaryOnly, .none:
            return .install
        }
    }

    /// Contract order: hello, then the CLI LaunchAgent plist, then a binary.
    static func detectExisting(probe: LeoDaemonProbeResult, paths: LeoInstallPaths, fileSystem: any LeoFileSystem) -> LeoExistingInstall {
        if case .live = probe { return .live }
        if fileSystem.kind(at: paths.cliLaunchAgentPlist) != .absent { return .installedStopped }
        let ownLink = paths.selfLinkURL.path
        let hasBinary = paths.cliBinaryCandidates.contains { url in
            switch fileSystem.kind(at: url) {
            case .file: true
            case .symlink(let target): target != ownLink
            case .absent, .directory: false
            }
        }
        return hasBinary ? .binaryOnly : .none
    }
}

extension LeoMarkerState {
    var isOurs: Bool {
        if case .ours = self { return true }
        return false
    }
}
