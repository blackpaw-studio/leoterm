import Foundation
import Testing

@testable import Ghostty

/// A9: where the app runs from decides whether managed features may start,
/// and the mover's every step is checked against a recording environment.
struct LeoAppLocationTests {
    // MARK: what B5's managed startup sees

    @Test(arguments: [
        (LeoAppLocationState.allowed, LeoAppLocation.inApplications, LeoAppLocation?.some(.inApplications)),
        (.allowed, .exempt, .exempt),
        (.declined(.translocated), .needsMove(.translocated), .needsMove(.translocated)),
        (.moved, .needsMove(.elsewhere), nil),
    ])
    func theManagedStartupSeesTheLocationAfterTheCheck(
        state: LeoAppLocationState, checked: LeoAppLocation, expected: LeoAppLocation?
    ) {
        #expect(state.resolvedLocation(checked) == expected)
    }

    // MARK: - Decision table

    private static func decide(
        _ path: String, _ kind: LeoBuildKind = .release, readOnly: Bool = false
    ) -> LeoAppLocation {
        LeoAppLocation.decide(bundleURL: URL(fileURLWithPath: path), buildKind: kind, isOnReadOnlyVolume: readOnly)
    }

    @Test func aReleaseBuildDirectlyInApplicationsIsHome() {
        #expect(Self.decide("/Applications/Leo.app") == .inApplications)
    }

    @Test(arguments: [
        "/Applications/Utilities/Leo.app",
        "/Applications/Sub/Leo.app",
        "/Users/evan/Applications/Leo.app",
        "/Users/evan/Downloads/Leo.app",
        "/Volumes/Leo 1.2/Leo.app",
        "/Applications.app/Leo.app",
    ])
    func anyOtherFolderNeedsAMove(path: String) {
        #expect(Self.decide(path) == .needsMove(.elsewhere))
    }

    @Test func aTrailingSlashOrDotSegmentStillCountsAsApplications() {
        #expect(Self.decide("/Applications/./Leo.app/") == .inApplications)
        #expect(Self.decide("/Applications/Sub/../Leo.app") == .inApplications)
    }

    @Test func gatekeeperTranslocationIsItsOwnReason() {
        let path = "/private/var/folders/ab/xyz/T/AppTranslocation/6B3C-1D2E/d/Leo.app"
        #expect(Self.decide(path) == .needsMove(.translocated))
        // Translocated copies are read-only too; the more specific reason wins.
        #expect(Self.decide(path, readOnly: true) == .needsMove(.translocated))
    }

    @Test func aReadOnlyVolumeIsReportedWhenNotTranslocated() {
        #expect(Self.decide("/Volumes/Leo/Leo.app", readOnly: true) == .needsMove(.readOnlyVolume))
    }

    @Test func aDebugBuildIsExemptEverywhere() {
        #expect(Self.decide("/Users/evan/build/Debug/Leo.app", .debug) == .exempt)
        #expect(Self.decide("/Applications/Leo.app", .debug) == .exempt)
        #expect(Self.decide("/private/var/folders/T/AppTranslocation/x/d/Leo.app", .debug, readOnly: true) == .exempt)
    }

    @Test func managedFeaturesAreOnlyOffForAnUnmovedApp() {
        #expect(LeoAppLocation.inApplications.allowsManagedFeatures)
        #expect(LeoAppLocation.exempt.allowsManagedFeatures)
        #expect(!LeoAppLocation.needsMove(.elsewhere).allowsManagedFeatures)
    }

    // MARK: - Mover

    private static let source = URL(fileURLWithPath: "/Volumes/Leo/Leo.app")
    private static let destination = URL(fileURLWithPath: "/Applications/Leo.app")
    private static let staging = URL(fileURLWithPath: "/Applications/.Leo.app.moving")
    private static let backup = URL(fileURLWithPath: "/Applications/.Leo.app.replaced")

    @MainActor private static func move(
        _ environment: RecordingMoverEnvironment, reason: LeoMoveReason = .elsewhere
    ) async -> LeoMoveOutcome {
        await LeoAppMover(environment: environment).move(bundleURL: source, reason: reason)
    }

    @MainActor @Test func aFreshMoveInstallsSchedulesTheHandoffThenAsksToQuit() async {
        let environment = RecordingMoverEnvironment()

        let outcome = await Self.move(environment)

        #expect(outcome == .relaunched)
        // Nothing is launched or trashed yet: that waits for the quit to be certain.
        #expect(environment.ops == [
            .copy(Self.source, Self.staging),
            .move(Self.staging, Self.destination),
            .scheduleHandoff(LeoMoveHandoff(destination: Self.destination, original: Self.source)),
            .terminate,
        ])
    }

    @MainActor @Test func anExistingIdleCopyIsKeptAsABackupUntilTheNewOneIsInstalled() async {
        let environment = RecordingMoverEnvironment(destination: .present(isRunning: false), replaceAnswer: true)

        let outcome = await Self.move(environment)

        #expect(outcome == .relaunched)
        #expect(environment.ops == [
            .askReplace(Self.destination),
            .copy(Self.source, Self.staging),
            .move(Self.destination, Self.backup),
            .move(Self.staging, Self.destination),
            .trash(Self.backup),
            .scheduleHandoff(LeoMoveHandoff(destination: Self.destination, original: Self.source)),
            .terminate,
        ])
    }

    @MainActor @Test func aFailedInstallRestoresTheInstalledCopyFromItsBackup() async {
        let environment = RecordingMoverEnvironment(
            destination: .present(isRunning: false), replaceAnswer: true, failingMoveSources: [Self.staging]
        )

        let outcome = await Self.move(environment)

        #expect(outcome == .failed("move failed"))
        #expect(environment.ops == [
            .askReplace(Self.destination),
            .copy(Self.source, Self.staging),
            .move(Self.destination, Self.backup),
            .move(Self.staging, Self.destination),
            .move(Self.backup, Self.destination),
            .report("move failed"),
        ])
    }

    @MainActor @Test func aFailedFirstInstallLeavesNothingToRestore() async {
        let environment = RecordingMoverEnvironment(failingMoveSources: [Self.staging])

        let outcome = await Self.move(environment)

        #expect(outcome == .failed("move failed"))
        #expect(environment.ops == [
            .copy(Self.source, Self.staging),
            .move(Self.staging, Self.destination),
            .report("move failed"),
        ])
    }

    @MainActor @Test func aFailedBackupMoveStopsBeforeTouchingTheInstalledCopy() async {
        let environment = RecordingMoverEnvironment(
            destination: .present(isRunning: false), replaceAnswer: true, failingMoveSources: [Self.destination]
        )

        let outcome = await Self.move(environment)

        #expect(outcome == .failed("move failed"))
        #expect(environment.ops == [
            .askReplace(Self.destination),
            .copy(Self.source, Self.staging),
            .move(Self.destination, Self.backup),
            .report("move failed"),
        ])
    }

    @MainActor @Test func decliningTheReplaceChangesNothing() async {
        let environment = RecordingMoverEnvironment(destination: .present(isRunning: false), replaceAnswer: false)

        let outcome = await Self.move(environment)

        #expect(outcome == .declinedReplace)
        #expect(environment.ops == [.askReplace(Self.destination)])
    }

    @MainActor @Test func aRunningCopyInApplicationsIsRefusedWithoutAsking() async {
        let environment = RecordingMoverEnvironment(destination: .present(isRunning: true))

        let outcome = await Self.move(environment)

        #expect(outcome == .refusedRunning)
        #expect(environment.ops == [.explainRunning(Self.destination)])
    }

    @MainActor @Test func anUnwritableApplicationsFolderShowsInstructionsAndRevealsTheApp() async {
        let environment = RecordingMoverEnvironment(isWritable: false)

        let outcome = await Self.move(environment)

        #expect(outcome == .manualInstructionsShown)
        #expect(environment.ops == [.showInstructions(Self.source)])
    }

    @MainActor @Test(arguments: [LeoMoveReason.translocated, .readOnlyVolume])
    func anOriginalThatCantBeTrashedIsNotHandedOff(reason: LeoMoveReason) async {
        let environment = RecordingMoverEnvironment()

        let outcome = await Self.move(environment, reason: reason)

        #expect(outcome == .relaunched)
        #expect(environment.ops == [
            .copy(Self.source, Self.staging),
            .move(Self.staging, Self.destination),
            .scheduleHandoff(LeoMoveHandoff(destination: Self.destination, original: nil)),
            .terminate,
        ])
    }

    @MainActor @Test func aFailedCopyReportsAndLeavesEverythingElseUntouched() async {
        let environment = RecordingMoverEnvironment(failing: [.copy])

        let outcome = await Self.move(environment)

        #expect(outcome == .failed("copy failed"))
        #expect(environment.ops == [.copy(Self.source, Self.staging), .report("copy failed")])
    }

    // MARK: - Handoff after the quit is certain

    private static let handoff = LeoMoveHandoff(destination: destination, original: source)

    @MainActor @Test func theHandoffWaitsForTheQuitAndRunsOnce() {
        let environment = RecordingMoverEnvironment()
        let coordinator = LeoMoveHandoffCoordinator(environment: environment)
        coordinator.arm(Self.handoff)

        coordinator.terminationAttemptBegan()
        #expect(environment.ops.isEmpty)

        coordinator.willTerminate()
        #expect(environment.ops == [.markExiting, .open(Self.destination), .trash(Self.source)])

        coordinator.willTerminate()
        #expect(environment.ops.count == 3)
    }

    @MainActor @Test func aCancelledQuitNeverHandsOffEvenWhenLeoQuitsLater() {
        let environment = RecordingMoverEnvironment()
        let coordinator = LeoMoveHandoffCoordinator(environment: environment)
        coordinator.arm(Self.handoff)
        coordinator.terminationAttemptBegan()
        // The user cancelled the quit prompt: no callback says so. Their next quit is a new attempt.
        coordinator.terminationAttemptBegan()

        coordinator.willTerminate()

        #expect(environment.ops.isEmpty)
    }

    @MainActor @Test func aFailedLaunchUnmarksTheInstanceAndTrashesNothing() {
        let environment = RecordingMoverEnvironment(failing: [.open])
        let coordinator = LeoMoveHandoffCoordinator(environment: environment)
        coordinator.arm(Self.handoff)

        coordinator.willTerminate()

        #expect(environment.ops == [.markExiting, .open(Self.destination), .clearExiting, .handoffFailed("open failed")])
    }

    @MainActor @Test func aTrashFailureOrNoOriginalNeverStopsTheLaunch() {
        let trashFails = RecordingMoverEnvironment(failing: [.trash])
        let first = LeoMoveHandoffCoordinator(environment: trashFails)
        first.arm(Self.handoff)
        first.willTerminate()
        #expect(trashFails.ops == [.markExiting, .open(Self.destination), .trash(Self.source)])

        let noOriginal = RecordingMoverEnvironment()
        let second = LeoMoveHandoffCoordinator(environment: noOriginal)
        second.arm(LeoMoveHandoff(destination: Self.destination, original: nil))
        second.willTerminate()
        #expect(noOriginal.ops == [.markExiting, .open(Self.destination)])
    }

    @MainActor @Test func theLiveEnvironmentDoesItsFileWorkOffTheMainThread() async throws {
        let fileManager = ThreadRecordingFileManager()
        let environment = LeoLiveMoverEnvironment(instanceClaim: .skipped("test"), fileManager: fileManager)
        #expect(Thread.isMainThread)

        try await environment.copyBundle(from: Self.source, to: Self.staging)
        try await environment.moveBundle(from: Self.staging, to: Self.destination)
        try await environment.trash(Self.backup)

        #expect(fileManager.calls.map(\.name) == ["copy", "move", "trash"])
        #expect(fileManager.calls.allSatisfy { !$0.onMainThread })
    }

    // MARK: - Prompt flow

    @MainActor @Test func notNowKeepsManagedFeaturesOffAndOffersTheBanner() async {
        let environment = RecordingMoverEnvironment()
        let gate = LeoAppLocationGate(
            location: .needsMove(.elsewhere), mover: LeoAppMover(environment: environment), bundleURL: Self.source,
            confirmMove: { _ in false }
        )

        let state = await gate.run()

        #expect(state == .declined(.elsewhere))
        #expect(state.allowsManagedFeatures == false)
        #expect(environment.ops.isEmpty)
    }

    @MainActor @Test func acceptingMovesAndAFailureKeepsTheBanner() async {
        let environment = RecordingMoverEnvironment(failing: [.copy])
        let gate = LeoAppLocationGate(
            location: .needsMove(.translocated), mover: LeoAppMover(environment: environment), bundleURL: Self.source,
            confirmMove: { _ in true }
        )

        let state = await gate.run()

        #expect(state == .declined(.translocated))
    }

    @MainActor @Test func homeAndExemptLocationsNeverPrompt() async {
        for location in [LeoAppLocation.inApplications, .exempt] {
            let gate = LeoAppLocationGate(
                location: location, mover: LeoAppMover(environment: RecordingMoverEnvironment()), bundleURL: Self.source,
                confirmMove: { _ in Issue.record("prompted"); return false }
            )
            #expect(await gate.run() == .allowed)
        }
    }
}

// MARK: - Recording environment

enum RecordedMoverOp: Equatable {
    case copy(URL, URL)
    case move(URL, URL)
    case trash(URL)
    case markExiting
    case clearExiting
    case open(URL)
    case terminate
    case askReplace(URL)
    case explainRunning(URL)
    case showInstructions(URL)
    case report(String)
    case scheduleHandoff(LeoMoveHandoff)
    case handoffFailed(String)
}

@MainActor final class RecordingMoverEnvironment: LeoAppMoverEnvironment, LeoMoveHandoffEnvironment {
    enum Failure { case copy, open, trash }

    private(set) var ops: [RecordedMoverOp] = []
    private let destination: LeoMoveDestinationState
    private let isWritable: Bool
    private let replaceAnswer: Bool
    private let failing: Set<Failure>
    private let failingMoveSources: Set<URL>

    init(
        destination: LeoMoveDestinationState = .absent, isWritable: Bool = true, replaceAnswer: Bool = true,
        failing: Set<Failure> = [], failingMoveSources: Set<URL> = []
    ) {
        self.destination = destination
        self.isWritable = isWritable
        self.replaceAnswer = replaceAnswer
        self.failing = failing
        self.failingMoveSources = failingMoveSources
    }

    func destinationState(at url: URL) -> LeoMoveDestinationState { destination }
    func isApplicationsWritable() -> Bool { isWritable }

    func copyBundle(from source: URL, to target: URL) throws {
        ops.append(.copy(source, target))
        if failing.contains(.copy) { throw RecordedError(message: "copy failed") }
    }

    func moveBundle(from source: URL, to target: URL) throws {
        ops.append(.move(source, target))
        if failingMoveSources.contains(source) { throw RecordedError(message: "move failed") }
    }

    func trash(_ url: URL) throws {
        ops.append(.trash(url))
        if failing.contains(.trash) { throw RecordedError(message: "trash failed") }
    }

    func markInstanceExiting() { ops.append(.markExiting) }
    func clearInstanceExiting() { ops.append(.clearExiting) }

    func terminate() { ops.append(.terminate) }
    func scheduleHandoff(_ handoff: LeoMoveHandoff) { ops.append(.scheduleHandoff(handoff)) }

    func launchNewInstance(at url: URL) throws {
        ops.append(.open(url))
        if failing.contains(.open) { throw RecordedError(message: "open failed") }
    }

    func trashOriginal(_ url: URL) throws {
        ops.append(.trash(url))
        if failing.contains(.trash) { throw RecordedError(message: "trash failed") }
    }

    func reportHandoffFailure(_ message: String) { ops.append(.handoffFailed(message)) }

    func askReplace(existing: URL) -> Bool {
        ops.append(.askReplace(existing))
        return replaceAnswer
    }

    func explainRunningCopy(at url: URL) { ops.append(.explainRunning(url)) }
    func showManualInstructions(for bundleURL: URL) { ops.append(.showInstructions(bundleURL)) }
    func report(error message: String) { ops.append(.report(message)) }

    struct RecordedError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Records which thread each heavy file operation ran on, and does none of them.
final class ThreadRecordingFileManager: FileManager, @unchecked Sendable {
    struct Call: Equatable { let name: String; let onMainThread: Bool }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }

    private func record(_ name: String) { lock.withLock { recorded.append(Call(name: name, onMainThread: Thread.isMainThread)) } }

    override func fileExists(atPath path: String) -> Bool { false }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws { record("copy") }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws { record("move") }
    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        record("trash")
    }
}
