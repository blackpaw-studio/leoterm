import Combine
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoPluginsSettingsModelTests {
    // MARK: Fakes

    private final class Log { var events: [String] = [] }

    private final class FakeManager: LeoPluginsManaging {
        let log: Log
        let subject: CurrentValueSubject<[LeoPluginInfo], Never>
        var plugins: [LeoPluginInfo] { subject.value }
        var pluginsChanged: AnyPublisher<[LeoPluginInfo], Never> { subject.eraseToAnyPublisher() }
        var uninstallError: Error?
        init(log: Log, plugins: [LeoPluginInfo]) {
            self.log = log
            subject = CurrentValueSubject(plugins)
        }
        func setEnabled(_ id: String, _ enabled: Bool) throws { log.events.append("setEnabled \(id) \(enabled)") }
        func approveCurrentPermissions(_ id: String) throws { log.events.append("approveCurrent \(id)") }
        func setSection(_ id: String, section: String, hidden: Bool) throws { log.events.append("section \(id) \(section) hidden=\(hidden)") }
        func setPane(_ id: String, pane: String, hidden: Bool) throws { log.events.append("pane \(id) \(pane) hidden=\(hidden)") }
        func uninstall(_ id: String) throws {
            if let uninstallError { throw uninstallError }
            log.events.append("uninstall \(id)")
        }
        func reload(restarting: Set<String>) { log.events.append("reload \(restarting.sorted().joined(separator: ","))") }
    }

    private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    private final class FakeInstaller: LeoPluginInstalling, @unchecked Sendable {
        let log: Log
        var staged: LeoPluginPendingInstall?
        var stagedDev: LeoPluginPendingDev?
        var stageError: Error?
        init(log: Log) { self.log = log }
        func stage(url: String, ref: String) async throws -> LeoPluginPendingInstall {
            log.events.append("stage \(url) \(ref)")
            if let stageError { throw stageError }
            return try #require(staged)
        }
        func confirm(_ pending: LeoPluginPendingInstall) throws { log.events.append("confirm \(pending.request.id)") }
        func cancel(_ pending: LeoPluginPendingInstall) throws { log.events.append("cancel \(pending.request.id)") }
        func stageDev(folder: URL) throws -> LeoPluginPendingDev {
            log.events.append("stageDev \(folder.path)")
            return try #require(stagedDev)
        }
        func confirmDev(_ pending: LeoPluginPendingDev) throws { log.events.append("confirmDev \(pending.request.id)") }
    }

    private final class FakeUpdater: LeoPluginUpdating, @unchecked Sendable {
        let log: Log
        var outcomes: [String: LeoPluginUpdateOutcome] = [:]
        var failures: [String: Error] = [:]
        init(log: Log) { self.log = log }
        func check(id: String) async throws -> LeoPluginUpdateOutcome {
            log.events.append("check \(id)")
            if let error = failures[id] { throw error }
            return try #require(outcomes[id])
        }
        func approve(_ pending: LeoPluginPendingUpdate) throws { log.events.append("approveUpdate \(pending.request.id)") }
        func discard(_ pending: LeoPluginPendingUpdate) { log.events.append("discard \(pending.request.id)") }
    }

    private struct Rig {
        let model: LeoPluginsSettingsModel
        let manager: FakeManager
        let installer: FakeInstaller
        let updater: FakeUpdater
        let log: Log
        let shown: Shown
    }

    /// The requests the approval sheet was asked to show, and the answer it gives.
    private final class Shown {
        var requests: [LeoPluginApprovalRequest] = []
        var answer = true
        var onShow: () -> Void = {}
    }

    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    private static func manifest(_ id: String = "dev.example.demo", network: [String] = [], secrets: Bool = false) -> LeoPluginManifest {
        LeoPluginManifest(
            id: id, name: "Demo", version: "1.2.0", apiVersion: 1, main: "main.js",
            permissions: LeoPluginPermissions(network: network, secrets: secrets, agents: []))
    }

    private static func info(
        _ id: String = "dev.example.demo", source: LeoPluginSource = .git(url: "https://github.com/acme/demo.git", ref: "main", sha: sha),
        enabled: Bool = true, state: LeoPluginRunState = .running, approved: LeoPluginPermissions = .none,
        manifest: LeoPluginManifest? = nil, hidden: [String] = [], hiddenPanes: [String] = []
    ) -> LeoPluginInfo {
        LeoPluginInfo(
            id: id, name: "Demo", version: "1.2.0", source: source, isEnabled: enabled, state: state, approvedPermissions: approved,
            manifest: manifest ?? Self.manifest(id), hiddenSections: hidden, hiddenPanes: hiddenPanes)
    }

    private static func rig(_ plugins: [LeoPluginInfo] = []) -> Rig {
        let log = Log()
        let manager = FakeManager(log: log, plugins: plugins)
        let installer = FakeInstaller(log: log)
        let updater = FakeUpdater(log: log)
        let shown = Shown()
        let model = LeoPluginsSettingsModel(
            manager: manager, installer: installer, updater: updater,
            approve: { request in
                log.events.append("approve \(request.id)")
                shown.requests.append(request)
                shown.onShow()
                return shown.answer
            })
        return Rig(model: model, manager: manager, installer: installer, updater: updater, log: log, shown: shown)
    }

    private static func pendingInstall(_ manifest: LeoPluginManifest) -> LeoPluginPendingInstall {
        let result = LeoPluginInstallResult(
            manifest: manifest, sha: sha, url: "https://github.com/acme/demo", ref: "main", directory: URL(fileURLWithPath: "/tmp/x"))
        let request = LeoPluginApprovalRequest(
            id: manifest.id, name: manifest.name, version: manifest.version, sha: sha, sourceDescription: result.url,
            permissions: manifest.permissions, diff: nil, isDev: false)
        return LeoPluginPendingInstall(result: result, request: request)
    }

    // MARK: Agent pane

    private static func paneManifest(_ id: String = "dev.example.demo") -> LeoPluginManifest {
        LeoPluginManifest(
            id: id, name: "Demo", version: "1.2.0", apiVersion: 1, main: "main.js",
            contributes: LeoPluginContributions(panes: [LeoPluginPaneContribution(id: "status", title: "Status")]))
    }

    @Test func aPluginWithAPaneOffersAShowAgentPaneSwitchThatIsOnUnlessHidden() throws {
        let shown = try #require(Self.rig([Self.info(manifest: Self.paneManifest())]).model.rows.first?.pane)
        #expect(shown.id == "status")
        #expect(shown.isShown)

        let hidden = try #require(Self.rig([Self.info(manifest: Self.paneManifest(), hiddenPanes: ["status"])]).model.rows.first?.pane)
        #expect(!hidden.isShown)
    }

    @Test func aPluginWithoutAPaneOffersNoSwitch() throws {
        #expect(try #require(Self.rig([Self.info()]).model.rows.first).pane == nil)
    }

    @Test func turningThePaneSwitchOffHidesItAndOnShowsIt() throws {
        let rig = Self.rig([Self.info(manifest: Self.paneManifest())])
        rig.model.setPaneShown("dev.example.demo", pane: "status", shown: false)
        rig.model.setPaneShown("dev.example.demo", pane: "status", shown: true)
        #expect(rig.log.events == ["pane dev.example.demo status hidden=true", "pane dev.example.demo status hidden=false"])
    }

    // MARK: Row presentation

    @Test func gitRowShowsNameVersionShortSHAAndSource() throws {
        let row = try #require(Self.rig([Self.info()]).model.rows.first)

        #expect(row.name == "Demo")
        #expect(row.version == "1.2.0")
        #expect(row.shortSHA == "0123456")
        #expect(row.sourceText == "github.com/acme/demo")
        #expect(!row.isDev && !row.isBundled && row.canUninstall)
        #expect(row.status == .running)
    }

    @Test func bundledRowIsBuiltInAndCannotBeUninstalled() throws {
        let row = try #require(Self.rig([Self.info(source: .bundled)]).model.rows.first)

        #expect(row.sourceText == "Built in")
        #expect(row.shortSHA == nil)
        #expect(row.isBundled && !row.canUninstall)
    }

    @Test func devRowIsBadgedAndShowsItsFolder() throws {
        let row = try #require(Self.rig([Self.info(source: .dev(path: "/Users/me/plugins/demo"))]).model.rows.first)

        #expect(row.isDev)
        #expect(row.shortSHA == nil)
        #expect(row.sourceText.hasSuffix("plugins/demo"))
        #expect(row.canUninstall)
    }

    @Test func permissionsSummaryListsWhatWasApproved() throws {
        let approved = LeoPluginPermissions(network: ["api.github.com"], secrets: true, agents: [.read, .send])
        let rows = Self.rig([Self.info("a.b.one", approved: approved), Self.info("a.b.two")]).model.rows

        #expect(rows[0].permissionsSummary == "Network: api.github.com · Keychain · Agents: read, send")
        #expect(rows[1].permissionsSummary == "No special access")
    }

    @Test func rowStatusFollowsTheRunState() {
        let diff = LeoPluginPermissionDiff(old: .none, new: LeoPluginPermissions(network: ["x.example.com"]))
        let rows = Self.rig([
            Self.info("a.b.off", enabled: false, state: .stoppedByUser),
            Self.info("a.b.approve", state: .needsApproval(diff)),
            Self.info("a.b.restart", state: .restarting(reason: "crashed")),
            Self.info("a.b.crash", state: .disabled(reason: "Turned off after repeated crashes: oops")),
            Self.info("a.b.bad", state: .refused("its folder is missing")),
        ]).model.rows

        #expect(rows.map(\.status) == [
            .off, .needsApproval(lines: ["Network: x.example.com"]), .restarting(reason: "crashed"),
            .crashDisabled(reason: "Turned off after repeated crashes: oops"), .refused(reason: "its folder is missing"),
        ])
        #expect(rows[0].isEnabled == false)
    }

    @Test func aPluginWaitingForApprovalShowsItsSwitchOffAndLocked() {
        let diff = LeoPluginPermissionDiff(old: .none, new: LeoPluginPermissions(network: ["x.example.com"]))
        let rows = Self.rig([
            Self.info("a.b.approve", enabled: true, state: .needsApproval(diff)),
            Self.info("a.b.on"),
            Self.info("a.b.off", enabled: false, state: .stoppedByUser),
        ]).model.rows

        #expect(rows[0].isEnabled)
        #expect(rows.map(\.switchIsOn) == [false, true, false])
        #expect(rows.map(\.canToggle) == [false, true, true])
    }

    @Test func rowsFollowTheManager() {
        let rig = Self.rig([Self.info("a.b.one")])
        rig.manager.subject.send([Self.info("a.b.one"), Self.info("a.b.two")])

        #expect(rig.model.rows.map(\.id) == ["a.b.one", "a.b.two"])
    }

    // MARK: Install

    @Test func installRunsNothingUntilTheSheetIsApproved() async {
        let rig = Self.rig()
        rig.installer.staged = Self.pendingInstall(Self.manifest(network: ["api.example.com"]))
        rig.shown.onShow = { #expect(rig.log.events == ["stage https://github.com/acme/demo main", "approve dev.example.demo"]) }

        await rig.model.install(url: "https://github.com/acme/demo", ref: "main")

        #expect(rig.log.events == ["stage https://github.com/acme/demo main", "approve dev.example.demo", "confirm dev.example.demo", "reload dev.example.demo"])
        #expect(rig.shown.requests.first?.permissionLines == ["Network: api.example.com"])
    }

    @Test func decliningAnInstallRemovesTheStagedCopyAndRegistersNothing() async {
        let rig = Self.rig()
        rig.installer.staged = Self.pendingInstall(Self.manifest())
        rig.shown.answer = false

        await rig.model.install(url: "https://github.com/acme/demo", ref: "")

        #expect(rig.log.events == ["stage https://github.com/acme/demo ", "approve dev.example.demo", "cancel dev.example.demo"])
    }

    @Test func aFailedStageShowsTheErrorAndNeverAsksForApproval() async {
        let rig = Self.rig()
        rig.installer.stageError = Boom()

        await rig.model.install(url: "https://github.com/acme/demo", ref: "main")

        #expect(rig.shown.requests.isEmpty)
        #expect(rig.model.message == .failure("boom"))
        #expect(!rig.model.isBusy)
    }

    @Test func loadingALocalFolderRunsNothingUntilTheSheetIsApproved() async {
        let rig = Self.rig()
        let folder = URL(fileURLWithPath: "/tmp/demo-plugin")
        let manifest = Self.manifest()
        let request = LeoPluginApprovalRequest(
            id: manifest.id, name: manifest.name, version: manifest.version, sha: nil, sourceDescription: folder.path,
            permissions: manifest.permissions, diff: nil, isDev: true)
        rig.installer.stagedDev = LeoPluginPendingDev(manifest: manifest, folder: folder, request: request)
        rig.shown.onShow = { #expect(rig.log.events == ["stageDev /tmp/demo-plugin", "approve dev.example.demo"]) }

        await rig.model.loadLocalFolder(folder)

        #expect(rig.log.events == ["stageDev /tmp/demo-plugin", "approve dev.example.demo", "confirmDev dev.example.demo", "reload dev.example.demo"])
        #expect(rig.shown.requests.first?.isDev == true)
    }

    @Test func decliningALocalFolderRegistersNothing() async {
        let rig = Self.rig()
        let folder = URL(fileURLWithPath: "/tmp/demo-plugin")
        let manifest = Self.manifest()
        let request = LeoPluginApprovalRequest(
            id: manifest.id, name: manifest.name, version: manifest.version, sha: nil, sourceDescription: folder.path,
            permissions: manifest.permissions, diff: nil, isDev: true)
        rig.installer.stagedDev = LeoPluginPendingDev(manifest: manifest, folder: folder, request: request)
        rig.shown.answer = false

        await rig.model.loadLocalFolder(folder)

        #expect(rig.log.events == ["stageDev /tmp/demo-plugin", "approve dev.example.demo"])
    }

    // MARK: Enable, re-enable, sections

    @Test func theToggleSwitchesThePluginThroughTheManager() {
        let rig = Self.rig([Self.info()])

        rig.model.setEnabled("dev.example.demo", false)
        rig.model.setEnabled("dev.example.demo", true)

        #expect(rig.log.events == ["setEnabled dev.example.demo false", "setEnabled dev.example.demo true"])
    }

    @Test func reEnableTurnsACrashDisabledPluginBackOnThroughTheManager() {
        let rig = Self.rig([Self.info(state: .disabled(reason: "Turned off after repeated crashes: oops"))])

        rig.model.reenable("dev.example.demo")

        #expect(rig.log.events == ["setEnabled dev.example.demo true"])
    }

    @Test func showingAHiddenSectionUnhidesIt() {
        let rig = Self.rig([Self.info(hidden: ["tasks"])])

        rig.model.showSection("dev.example.demo", section: "tasks")

        #expect(rig.log.events == ["section dev.example.demo tasks hidden=false"])
    }

    // MARK: Approval

    private static let growth = LeoPluginPermissions(network: ["new.example.com"], secrets: true)

    private static func needsApproval(source: LeoPluginSource = .bundled) -> LeoPluginInfo {
        let diff = LeoPluginPermissionDiff(old: .none, new: growth)
        return info(
            source: source, state: .needsApproval(diff),
            manifest: LeoPluginManifest(id: "dev.example.demo", name: "Demo", version: "2.0.0", apiVersion: 1, main: "main.js", permissions: growth))
    }

    @Test func approvingShowsTheDiffAndThenApprovesTheManifestThatWasShown() async {
        let rig = Self.rig([Self.needsApproval()])
        rig.shown.onShow = { #expect(!rig.log.events.contains("approveCurrent dev.example.demo")) }

        await rig.model.reviewApproval("dev.example.demo")

        #expect(rig.shown.requests.first?.permissionLines == ["Network: new.example.com", "Keychain: stores secrets such as access tokens"])
        #expect(rig.shown.requests.first?.isUpdate == true)
        #expect(rig.log.events == ["approve dev.example.demo", "approveCurrent dev.example.demo"])
    }

    @Test func decliningApprovalLeavesThePluginStopped() async {
        let rig = Self.rig([Self.needsApproval()])
        rig.shown.answer = false

        await rig.model.reviewApproval("dev.example.demo")

        #expect(rig.log.events == ["approve dev.example.demo"])
    }

    @Test func approvalIsRefusedWhenThePluginAsksForMoreWhileTheSheetIsOpen() async {
        let rig = Self.rig([Self.needsApproval()])
        let more = LeoPluginPermissions(network: ["new.example.com", "evil.example.com"], secrets: true)
        let moreDiff = LeoPluginPermissionDiff(old: .none, new: more)
        rig.shown.onShow = {
            rig.manager.subject.send([Self.info(
                source: .bundled, state: .needsApproval(moreDiff),
                manifest: LeoPluginManifest(id: "dev.example.demo", name: "Demo", version: "2.0.0", apiVersion: 1, main: "main.js", permissions: more))])
        }

        await rig.model.reviewApproval("dev.example.demo")

        #expect(!rig.log.events.contains("approveCurrent dev.example.demo"))
        if case .failure? = rig.model.message {} else { Issue.record("expected a failure message") }
    }

    @Test func aPluginThatIsNotWaitingOnApprovalHasNothingToReview() async {
        let rig = Self.rig([Self.info()])

        await rig.model.reviewApproval("dev.example.demo")

        #expect(rig.log.events.isEmpty)
    }

    // MARK: Updates

    @Test func checkForUpdatesChecksOnlyGitPluginsAndRestartsTheOnesThatMoved() async {
        let rig = Self.rig([
            Self.info("a.b.git"), Self.info("a.b.bundled", source: .bundled), Self.info("a.b.dev", source: .dev(path: "/tmp/d")),
            Self.info("a.b.same"),
        ])
        let result = LeoPluginInstallResult(
            manifest: Self.manifest("a.b.git"), sha: String(repeating: "a", count: 40), url: "u", ref: "main", directory: URL(fileURLWithPath: "/tmp"))
        rig.updater.outcomes = ["a.b.git": .updated(result), "a.b.same": .upToDate(sha: Self.sha)]

        await rig.model.checkForUpdates()

        #expect(rig.log.events == ["check a.b.git", "check a.b.same", "reload a.b.git"])
        #expect(rig.model.message == .notice("1 plugin updated."))
    }

    @Test func anUpdateThatAddsPermissionsAsksFirstAndThenApplies() async {
        let rig = Self.rig([Self.info()])
        rig.updater.outcomes = ["dev.example.demo": .needsApproval(Self.pendingUpdate())]
        rig.shown.onShow = { #expect(rig.log.events == ["check dev.example.demo", "approve dev.example.demo"]) }

        await rig.model.checkForUpdates()

        #expect(rig.log.events == ["check dev.example.demo", "approve dev.example.demo", "approveUpdate dev.example.demo", "reload dev.example.demo"])
    }

    @Test func decliningAnUpdateDiscardsTheStagedCommit() async {
        let rig = Self.rig([Self.info()])
        rig.updater.outcomes = ["dev.example.demo": .needsApproval(Self.pendingUpdate())]
        rig.shown.answer = false

        await rig.model.checkForUpdates()

        #expect(rig.log.events == ["check dev.example.demo", "approve dev.example.demo", "discard dev.example.demo"])
    }

    @Test func oneFailedCheckDoesNotStopTheOthers() async {
        let rig = Self.rig([Self.info("a.b.one"), Self.info("a.b.two")])
        rig.updater.failures = ["a.b.one": Boom()]
        rig.updater.outcomes = ["a.b.two": .upToDate(sha: Self.sha)]

        await rig.model.checkForUpdates()

        #expect(rig.log.events == ["check a.b.one", "check a.b.two"])
        #expect(rig.model.message == .failure("Demo: boom"))
    }

    private static func pendingUpdate() -> LeoPluginPendingUpdate {
        let manifest = Self.manifest(network: ["new.example.com"])
        let diff = LeoPluginPermissionDiff(old: .none, new: manifest.permissions)
        let result = LeoPluginInstallResult(
            manifest: manifest, sha: String(repeating: "b", count: 40), url: "https://github.com/acme/demo", ref: "main",
            directory: URL(fileURLWithPath: "/tmp"))
        let request = LeoPluginApprovalRequest(
            id: manifest.id, name: manifest.name, version: manifest.version, sha: result.sha, sourceDescription: result.url,
            permissions: manifest.permissions, diff: diff, isDev: false)
        return LeoPluginPendingUpdate(result: result, fromSHA: sha, diff: diff, request: request)
    }

    // MARK: Uninstall

    @Test func uninstallWaitsForTheConfirmation() throws {
        let rig = Self.rig([Self.info()])

        rig.model.requestUninstall("dev.example.demo")
        #expect(rig.model.pendingUninstall?.id == "dev.example.demo")
        #expect(rig.log.events.isEmpty)

        rig.model.confirmUninstall()

        #expect(rig.log.events == ["uninstall dev.example.demo"])
        #expect(rig.model.pendingUninstall == nil)
    }

    @Test func cancellingTheConfirmationUninstallsNothing() {
        let rig = Self.rig([Self.info()])

        rig.model.requestUninstall("dev.example.demo")
        rig.model.cancelUninstall()

        #expect(rig.log.events.isEmpty)
        #expect(rig.model.pendingUninstall == nil)
    }

    @Test func aBundledPluginCannotBeQueuedForUninstall() {
        let rig = Self.rig([Self.info(source: .bundled)])

        rig.model.requestUninstall("dev.example.demo")

        #expect(rig.model.pendingUninstall == nil)
    }

    @Test func aFailedUninstallShowsTheError() {
        let rig = Self.rig([Self.info()])
        rig.manager.uninstallError = Boom()

        rig.model.requestUninstall("dev.example.demo")
        rig.model.confirmUninstall()

        #expect(rig.model.message == .failure("boom"))
    }
}
