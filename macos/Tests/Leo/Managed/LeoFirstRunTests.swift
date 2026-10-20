import Foundation
import Testing

@testable import Ghostty

/// B1: the launch-time decision, one row per transition, and how an existing
/// leo install outside the app is detected (the first match wins).
struct LeoFirstRunTests {
    private static let ours = LeoManagedMarker(
        bundleID: "studio.blackpaw.leo.macos",
        launchdLabel: "studio.blackpaw.leo.daemon",
        selfPath: "/home/test/.leo/app/bin/leo",
        tmuxPath: "/home/test/.leo/app/tmux/3.6b/tmux",
        env: nil
    )
    private static let foreign = LeoManagedMarker(
        bundleID: "studio.blackpaw.leo.macos.debug",
        launchdLabel: "studio.blackpaw.leo.daemon.debug",
        selfPath: "/home/test/.leo/app/bin/leo",
        tmuxPath: "/home/test/.leo/app/tmux/3.6b/tmux",
        env: nil
    )

    /// A Release build in /Applications, no daemon, no marker, no install.
    private static let fresh = LeoFirstRunInputs(
        location: .inApplications,
        probe: .absent,
        marker: .absent,
        existing: .none,
        agentStatus: .notRegistered,
        takeover: .notAsked,
        buildKind: .release,
        managedDebug: false,
        hasBundledHelpers: true
    )

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let inputs: LeoFirstRunInputs
        let expected: LeoFirstRunAction
        var testDescription: String { name }

        init(_ name: String, _ expected: LeoFirstRunAction, _ change: (inout LeoFirstRunInputs) -> Void = { _ in }) {
            var inputs = LeoFirstRunTests.fresh
            change(&inputs)
            self.name = name
            self.inputs = inputs
            self.expected = expected
        }
    }

    static let rows: [Row] = [
        // Nothing to take over.
        Row("fresh install", .install),
        Row("binary only: no takeover, just start the managed daemon", .install) { $0.existing = .binaryOnly },

        // An existing CLI daemon.
        Row("live CLI hello offers takeover", .useLive(offerTakeover: true)) {
            $0.probe = .live(version: "0.55.0"); $0.existing = .live
        },
        Row("CLI plist present, daemon stopped, offers takeover", .useLive(offerTakeover: true)) { $0.existing = .installedStopped },
        Row("declined offer is not repeated (live)", .useLive(offerTakeover: false)) {
            $0.probe = .live(version: "0.55.0"); $0.existing = .live; $0.takeover = .declined
        },
        Row("declined offer is not repeated (stopped)", .useLive(offerTakeover: false)) {
            $0.existing = .installedStopped; $0.takeover = .declined
        },
        Row("no_launchd_job: keep using the live daemon, no offer", .useLive(offerTakeover: false)) {
            $0.probe = .live(version: "0.55.0"); $0.existing = .live; $0.takeover = .unavailable
        },
        Row("no_launchd_job, later stopped with its plist: handover supports that", .useLive(offerTakeover: true)) {
            $0.existing = .installedStopped; $0.takeover = .unavailable
        },
        Row("something holds the socket but doesn't answer: never install over it", .useLive(offerTakeover: false)) {
            $0.probe = .unresponsive
        },

        // Crash-between-steps recovery after Release to CLI.
        Row("marker absent, agent enabled", .recoverOrphanRegistration) { $0.agentStatus = .enabled },
        Row("marker absent, agent awaiting approval", .recoverOrphanRegistration) { $0.agentStatus = .requiresApproval },
        Row("marker absent, agent enabled, CLI daemon live", .recoverOrphanRegistration) {
            $0.agentStatus = .enabled; $0.probe = .live(version: "0.57.0"); $0.existing = .live
        },

        // Already managed by this bundle.
        Row("managed and running", .ensureManaged(refreshLink: true, register: false)) {
            $0.marker = .ours(Self.ours); $0.agentStatus = .enabled; $0.probe = .live(version: "0.57.0"); $0.existing = .live
        },
        Row("managed, daemon not up yet", .ensureManaged(refreshLink: true, register: false)) {
            $0.marker = .ours(Self.ours); $0.agentStatus = .enabled
        },
        Row("managed but unregistered: register again", .ensureManaged(refreshLink: true, register: true)) {
            $0.marker = .ours(Self.ours)
        },
        Row("managed, awaiting Login Items approval", .awaitApproval) {
            $0.marker = .ours(Self.ours); $0.agentStatus = .requiresApproval
        },

        // Repair and blocking states (B9).
        Row("invalid marker is rewritten and registered again", .repair(.invalidMarker("malformed JSON"))) {
            $0.marker = .invalid("malformed JSON"); $0.agentStatus = .enabled
        },
        Row("managed app moved out of Applications", .blockMove(isManaged: true)) {
            $0.location = .needsMove(.elsewhere); $0.marker = .ours(Self.ours); $0.agentStatus = .enabled
        },
        Row("unmanaged app outside Applications", .blockMove(isManaged: false)) {
            $0.location = .needsMove(.translocated); $0.probe = .live(version: "0.55.0"); $0.existing = .live
        },
        Row("managed, bundle has no helpers", .repair(.bundleIncomplete)) {
            $0.marker = .ours(Self.ours); $0.agentStatus = .enabled; $0.hasBundledHelpers = false
        },
        Row("managed, bundle has no LaunchAgent plist", .repair(.bundleIncomplete)) {
            $0.marker = .ours(Self.ours); $0.agentStatus = .notFound
        },
        Row("unmanaged, bundle has no helpers: behave as before", .observeOnly) { $0.hasBundledHelpers = false },
        Row("unmanaged, bundle has no LaunchAgent plist", .observeOnly) { $0.agentStatus = .notFound },

        // Observe only.
        Row("foreign marker", .observeOnly) { $0.marker = .foreign(bundleID: Self.foreign.bundleID, marker: Self.foreign) },
        Row("debug build", .observeOnly) { $0.location = .exempt; $0.buildKind = .debug },
        Row("debug build, even with a stale orphan registration", .observeOnly) {
            $0.location = .exempt; $0.buildKind = .debug; $0.agentStatus = .enabled
        },
        Row("debug with LEO_MANAGED_DEBUG installs", .install) {
            $0.location = .exempt; $0.buildKind = .debug; $0.managedDebug = true
        },
        Row("debug with LEO_MANAGED_DEBUG never repoints the release link", .ensureManaged(refreshLink: false, register: false)) {
            $0.location = .exempt; $0.buildKind = .debug; $0.managedDebug = true
            $0.marker = .ours(Self.ours); $0.agentStatus = .enabled
        },
    ]

    @Test(arguments: rows)
    func decides(row: Row) {
        #expect(LeoFirstRun.decide(row.inputs) == row.expected)
    }

    @Test func managementNeedsAReleaseBuildOrTheDebugOptIn() {
        #expect(LeoFirstRun.isManagementEnabled(buildKind: .release, environment: [:]))
        #expect(!LeoFirstRun.isManagementEnabled(buildKind: .debug, environment: [:]))
        #expect(!LeoFirstRun.isManagementEnabled(buildKind: .debug, environment: ["LEO_MANAGED_DEBUG": "0"]))
        #expect(LeoFirstRun.isManagementEnabled(buildKind: .debug, environment: ["LEO_MANAGED_DEBUG": "1"]))
    }

    // MARK: - Existing install detection

    private static let paths = LeoInstallPaths(
        home: URL(fileURLWithPath: "/home/test", isDirectory: true),
        bundleURL: URL(fileURLWithPath: "/Applications/Leo.app")
    )

    private func detect(_ probe: LeoDaemonProbeResult, _ arrange: (LeoInMemoryFileSystem) -> Void = { _ in }) -> LeoExistingInstall {
        let fileSystem = LeoInMemoryFileSystem()
        arrange(fileSystem)
        return LeoFirstRun.detectExisting(probe: probe, paths: Self.paths, fileSystem: fileSystem)
    }

    @Test func helloIsAuthoritative() {
        #expect(detect(.live(version: "0.55.0")) == .live)
    }

    @Test func theCLILaunchAgentPlistMeansInstalledButStopped() {
        #expect(detect(.absent) { $0.addFile("/home/test/Library/LaunchAgents/com.blackpaw.leo.plist") } == .installedStopped)
        #expect(detect(.unresponsive) { $0.addFile("/home/test/Library/LaunchAgents/com.blackpaw.leo.plist") } == .installedStopped)
    }

    @Test(arguments: ["/home/test/.local/bin/leo", "/opt/homebrew/bin/leo", "/usr/local/bin/leo"])
    func aCLIBinaryAloneIsBinaryOnly(path: String) {
        #expect(detect(.absent) { $0.addFile(path, mode: 0o755) } == .binaryOnly)
    }

    @Test func ourOwnCommandLinkIsNotACLIInstall() {
        #expect(detect(.absent) { $0.addSymlink("/home/test/.local/bin/leo", to: "/home/test/.leo/app/bin/leo") } == .none)
    }

    @Test func nothingFoundIsNone() {
        #expect(detect(.absent) == .none)
    }
}
