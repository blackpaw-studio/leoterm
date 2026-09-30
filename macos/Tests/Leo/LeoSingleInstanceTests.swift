import AppKit
import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Leo is single-instance per bundle ID (D-051): a second copy of the same
/// bundle activates the first and quits before any tunnel state is touched,
/// and a lock that can't be taken safely stops the launch (fails closed).
struct LeoSingleInstanceTests {
    private static let bundleID = "studio.blackpaw.leo.macos.tests"

    // MARK: - Decision

    @Test func acquiredLockContinuesLaunching() {
        let spy = GateSpy()

        let claim = spy.gate(acquire: { _ in .acquired(LeoInstanceLock(descriptor: -1)) }).claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.activated.isEmpty)
        #expect(spy.alerts.isEmpty)
        #expect(spy.exits.isEmpty)
    }

    @Test func busyLockActivatesTheOtherCopyAndExitsCleanly() {
        let spy = GateSpy()

        let claim = spy.gate(acquire: { _ in .busy }).claim()

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.alerts.isEmpty)
        #expect(spy.exits == [0])
        #expect(spy.waits.isEmpty)
    }

    /// B-092: the holder is quitting (it marked the lock when its quit was
    /// approved), so this copy waits for it to go and carries on as the
    /// primary instead of yielding to a dying copy.
    @Test func anExitingHolderIsWaitedForNotYieldedTo() {
        let spy = GateSpy()

        let claim = spy.gate(acquire: { _ in .holderExiting }, wait: { _ in .acquired(LeoInstanceLock(descriptor: -1)) }).claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.waits == [Self.bundleID])
        #expect(spy.activated.isEmpty)
        #expect(spy.alerts.isEmpty)
        #expect(spy.exits.isEmpty)
    }

    /// The wait ends the way a first attempt would: busy still yields (D-051).
    @Test func aWaitThatEndsBusyStillYields() {
        let spy = GateSpy()

        let claim = spy.gate(acquire: { _ in .holderExiting }, wait: { _ in .busy }).claim()

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.exits == [0])
    }

    /// ... and a refusal still alerts and quits non-zero (D-053).
    @Test func aRefusedWaitAlertsAndQuitsNonZero() {
        let spy = GateSpy()
        let refusal = LeoInstanceLockRefusal(error: .linked, path: "/c/leo/x.instance.lock")

        let claim = spy.gate(acquire: { _ in .holderExiting }, wait: { _ in .refused(refusal) }).claim()

        guard case .refused = claim else { Issue.record("expected .refused, got \(claim)"); return }
        #expect(spy.alerts == [refusal])
        #expect(spy.exits == [1])
        #expect(spy.activated.isEmpty)
    }

    @Test func aTestHostNeverTakesTheLockOrQuits() {
        let spy = GateSpy()
        var attempts = 0

        let claim = spy.gate(isTestHost: true, acquire: { _ in attempts += 1; return .busy }).claim()

        guard case .skipped = claim else { Issue.record("expected .skipped, got \(claim)"); return }
        #expect(attempts == 0)
        #expect(spy.exits.isEmpty)
    }

    /// Fails closed: a lock that can't be taken safely means another copy
    /// might be running unseen, so this one explains why and quits non-zero.
    @Test func aRefusedLockAlertsAndQuitsNonZero() {
        let spy = GateSpy()
        let refusal = LeoInstanceLockRefusal(error: .notOwned, path: "/c/leo/x.instance.lock")

        let claim = spy.gate(acquire: { _ in .refused(refusal) }).claim()

        guard case .refused = claim else { Issue.record("expected .refused, got \(claim)"); return }
        #expect(spy.alerts == [refusal])
        #expect(spy.exits == [1])
        #expect(spy.activated.isEmpty)
    }

    /// No bundle ID, no bundle-keyed shared state to protect: launch.
    @Test func aMissingBundleIdentifierSkips() {
        let spy = GateSpy()
        let gate = LeoSingleInstance(
            bundleIdentifier: nil, isTestHost: false,
            acquireLock: { _ in Issue.record("must not lock"); return .busy }, waitForLock: spy.wait,
            activateOther: spy.activate, alert: spy.alert, terminate: spy.exit
        )

        guard case .skipped = gate.claim() else { Issue.record("expected .skipped"); return }
        #expect(spy.exits.isEmpty)
        #expect(spy.waits.isEmpty)
    }

    // MARK: - Test-host detection

    /// This very suite runs hosted in the debug Leo.app, which must not
    /// have quit (or taken the lock) whether or not a debug copy is running.
    @Test func theRealEnvironmentOfThisTestRunIsATestHost() {
        #expect(LeoSingleInstance.isRunningAsTestHost())
    }

    @Test func aStrayXCTestVariableNamingAnotherExecutableIsNotATestHost() throws {
        let own = try #require(Bundle.main.executablePath)
        let images = ["/usr/lib/libXCTestBundleInject.dylib"]
        let strays: [[String: String]] = [
            ["XCInjectBundleInto": "/Applications/Other.app/Contents/MacOS/Other"],
            ["XCInjectBundleInto": "/nonexistent/Leo"],
            ["XCTestConfigurationFilePath": "/x", "XCTestBundlePath": "/x", "XCTestSessionIdentifier": "x"],
        ]

        for environment in strays {
            #expect(!LeoSingleInstance.isTestHost(
                environment: environment, executablePath: own, bundlePath: Bundle.main.bundlePath, loadedImages: images
            ), "\(environment)")
        }
    }

    /// A direct `-XCTest` run: the injector names this executable, the
    /// injector is loaded, and so is the executable of one of this app's
    /// `.xctest` plug-ins -- any one missing and it's not a test host.
    @Test func aDirectInjectionIsATestHostOnlyWithTheInjectorAndAPlugInsExecutableLoaded() throws {
        let app = try FakeHostApp()
        defer { app.remove() }

        #expect(app.isDirectTestHost())
        #expect(!app.isDirectTestHost(loadedImages: [app.testExecutable]), "no injector")
        #expect(!app.isDirectTestHost(loadedImages: [FakeHostApp.injector]), "no test bundle loaded")
        #expect(!app.isDirectTestHost(loadedImages: [FakeHostApp.injector, app.helperImage]), "only another image in the plug-in")
        #expect(!app.isDirectTestHost(loadedImages: [FakeHostApp.injector, app.strayExecutable]), "only a .xctest outside PlugIns")
    }

    /// `xcodebuild test` (and Xcode) launch the host with
    /// `XCInjectBundleInto=unused` and name the test bundle, relative to the
    /// app, in `XCTestBundlePath`. Missing this let a parallel test worker
    /// find its sibling holding the lock and `exit(0)` mid-run.
    @Test func xcodebuildsInjectionOfALoadedPlugInTestBundleIsATestHost() throws {
        let app = try FakeHostApp()
        defer { app.remove() }

        for testBundle in [FakeHostApp.plugIn, app.path + "/" + FakeHostApp.plugIn] {
            #expect(app.isTestHost(testBundle), "\(testBundle)")
            #expect(!app.isTestHost(testBundle, loadedImages: [FakeHostApp.injector]), "\(testBundle): test bundle not loaded")
            #expect(!app.isTestHost(testBundle, loadedImages: [app.testExecutable]), "\(testBundle): no injector")
            #expect(!app.isTestHost(testBundle, loadedImages: [FakeHostApp.injector, app.helperImage]), "\(testBundle): only another image")
        }
    }

    /// A symlinked `Contents/PlugIns` is still this app's plug-ins directory.
    @Test func aSymlinkedPlugInsDirectoryStillCounts() throws {
        let app = try FakeHostApp(symlinkedPlugIns: true)
        defer { app.remove() }

        #expect(app.isTestHost(FakeHostApp.plugIn))
        #expect(app.isDirectTestHost())
        #expect(!app.isDirectTestHost(loadedImages: [FakeHostApp.injector, app.helperImage]))
    }

    /// Only an `.xctest` directory directly in this app's `Contents/PlugIns`
    /// counts -- not any file in the app, another directory, an `.xctest`
    /// elsewhere, a path that climbs out, or one that doesn't exist -- and
    /// only when that bundle's own executable is loaded.
    @Test func aTestBundlePathThatIsNotALoadedPlugInTestBundleIsNotATestHost() throws {
        let app = try FakeHostApp()
        defer { app.remove() }
        let rejected = [
            "Contents/Info.plist", "Contents/Resources", "Contents/PlugIns", "Contents/Stray.xctest",
            "Contents/PlugIns/Nested/Deep.xctest", "Contents/PlugIns/Plain.xctest",
            "Contents/PlugIns/Missing.xctest", "/tmp", "Contents/../..", "",
        ]

        for testBundle in rejected {
            let images = [FakeHostApp.injector, app.testExecutable, app.path + "/" + testBundle + "/Contents/MacOS/X"]
            #expect(!app.isTestHost(testBundle, loadedImages: images), "\(testBundle)")
        }
        #expect(!LeoSingleInstance.isTestHost(
            environment: ["XCTestBundlePath": FakeHostApp.plugIn], executablePath: nil, bundlePath: nil,
            loadedImages: [FakeHostApp.injector, app.testExecutable]
        ), "no bundle path")
    }

    // MARK: - Refusal reasons: each alerts and quits, never launches

    enum Refusal: String, CaseIterable {
        case symlink, directoryAtLockPath, foreignOwner, hardLinked, badBundleID, symlinkedLockDirectory
    }

    @Test(arguments: Refusal.allCases)
    func everyRefusalAlertsWithThePathAndQuitsNonZero(_ refusal: Refusal) throws {
        let parent = try LeoTestSocketDirectory()
        defer { parent.remove() }
        var directory = parent.url
        var bundleID = Self.bundleID
        var owner = geteuid()
        let lockPath = { directory.appendingPathComponent(LeoInstanceLock.fileName(for: bundleID)).path }
        let expectedPath: String
        switch refusal {
        case .symlink:
            try FileManager.default.createSymbolicLink(atPath: lockPath(), withDestinationPath: parent.path("target"))
            expectedPath = lockPath()
        case .directoryAtLockPath:
            try FileManager.default.createDirectory(atPath: lockPath(), withIntermediateDirectories: false)
            expectedPath = lockPath()
        case .foreignOwner:
            owner += 1
            expectedPath = directory.path
        case .hardLinked:
            #expect(FileManager.default.createFile(atPath: lockPath(), contents: nil, attributes: [.posixPermissions: 0o600]))
            #expect(link(lockPath(), parent.path("other")) == 0)
            expectedPath = lockPath()
        case .badBundleID:
            bundleID = "../escape"
            expectedPath = "../escape"
        case .symlinkedLockDirectory:
            directory = parent.url.appendingPathComponent("leo", isDirectory: true)
            try FileManager.default.createDirectory(atPath: parent.path("real"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: parent.path("real"))
            expectedPath = directory.path
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: parent.url.path).sorted()
        let spy = GateSpy()
        let gate = LeoSingleInstance(
            bundleIdentifier: bundleID, isTestHost: false,
            acquireLock: { [directory, owner] in LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory, owner: owner) },
            waitForLock: spy.wait, activateOther: spy.activate, alert: spy.alert, terminate: spy.exit
        )

        let claim = gate.claim()

        guard case .refused = claim else { Issue.record("expected .refused, got \(claim)"); return }
        #expect(spy.exits == [1])
        #expect(spy.activated.isEmpty)
        #expect(spy.waits.isEmpty)
        #expect(spy.alerts.count == 1)
        #expect(spy.alerts.first?.message.contains(expectedPath) == true, "\(spy.alerts)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.url.path).sorted() == before, "nothing is removed or created")
    }

    @Test func refusalMessagesNameTheProblemAndTheFix() {
        let path = "/c/leo/x.instance.lock"

        #expect(LeoInstanceLockRefusal(error: .notARegularFile, path: path).message
            == "\(path) is a symlink or not a regular file. Remove it and open Leo again.")
        #expect(LeoInstanceLockRefusal(error: .linked, path: path).message
            == "\(path) has other hard links. Remove it and open Leo again.")
        #expect(LeoInstanceLockRefusal(error: .notOwned, path: path).message
            == "\(path) belongs to another user. Remove it and open Leo again.")
    }

    // MARK: - Lock file

    @Test func theLockFileIsCreated0600InAFreshPrivateDirectory() throws {
        let parent = try LeoTestSocketDirectory()
        defer { parent.remove() }
        let directory = parent.url.appendingPathComponent("leo", isDirectory: true)

        let attempt = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory)

        guard case .acquired = attempt else { Issue.record("expected .acquired, got \(attempt)"); return }
        var info = Darwin.stat()
        #expect(lstat(directory.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        let path = directory.appendingPathComponent(LeoInstanceLock.fileName(for: Self.bundleID)).path
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())
    }

    @Test func aSecondAcquireIsBusyUntilTheFirstIsReleased() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        var first: LeoInstanceLock? = try #require(Self.acquired(LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url)))

        let second = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url)
        guard case .busy = second else { Issue.record("expected .busy, got \(second)"); return }

        withExtendedLifetime(first) {}
        first = nil
        let third = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url)
        guard case .acquired = third else { Issue.record("expected .acquired after release, got \(third)"); return }
    }

    @Test func distinctBundleIdentifiersDoNotCollide() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let release = LeoInstanceLock.acquire(bundleIdentifier: "studio.blackpaw.leo.macos", in: directory.url)
        let debug = LeoInstanceLock.acquire(bundleIdentifier: "studio.blackpaw.leo.macos.debug", in: directory.url)

        guard case .acquired = release, case .acquired = debug else {
            Issue.record("expected both acquired, got \(release) / \(debug)")
            return
        }
    }

    @Test func aLooseExistingLockFileIsTightenedTo0600() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let path = directory.path(LeoInstanceLock.fileName(for: Self.bundleID))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o666]))

        let attempt = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url)

        guard case .acquired = attempt else { Issue.record("expected .acquired, got \(attempt)"); return }
        var info = Darwin.stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test(arguments: ["", "../escape", "a/b", ".", ".."])
    func anUnsafeBundleIdentifierIsRefused(bundleID: String) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }

        let attempt = LeoInstanceLock.acquire(bundleIdentifier: bundleID, in: directory.url)

        guard case .refused = attempt else { Issue.record("expected .refused, got \(attempt)"); return }
    }

    // MARK: - A holder that is quitting (B-092)

    /// B-092: a copy launched ~50 ms into the previous copy's quit found the
    /// lock still held, activated the dying copy and exited 0, leaving no
    /// Leo. Now the quitting holder marks the lock, and the new copy waits
    /// for it to go and becomes the primary. Dropping `holder` in the wait
    /// seam stands in for the dying copy's process ending.
    @Test func aCopyLaunchedWhileTheHolderIsExitingTakesOverInsteadOfQuitting() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        var holder: LeoInstanceLock? = try Self.heldLock(in: directory)
        #expect(holder?.markExiting() == true)
        let spy = GateSpy()
        let gate = spy.gate(
            acquire: { LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory.url) },
            wait: { bundleID in
                holder = nil
                return LeoInstanceLock.waitAndAcquire(bundleIdentifier: bundleID, in: directory.url)
            }
        )

        let claim = gate.claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.waits == [Self.bundleID])
        #expect(spy.exits.isEmpty)
        #expect(spy.activated.isEmpty)
        #expect(spy.alerts.isEmpty)
    }

    /// D-051 still holds: a live holder that isn't quitting is activated and
    /// this copy exits 0 without waiting.
    @Test func aLiveHolderWithoutTheExitingMarkIsStillYieldedTo() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try Self.heldLock(in: directory)
        let spy = GateSpy()

        let claim = withExtendedLifetime(holder) {
            spy.gate(acquire: { LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory.url) }).claim()
        }

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.exits == [0])
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.waits.isEmpty)
    }

    @Test func markingExitingKeepsTheLockHeld() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try Self.heldLock(in: directory)

        #expect(holder.markExiting())
        let second = withExtendedLifetime(holder) { LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url) }

        guard case .holderExiting = second else { Issue.record("expected .holderExiting, got \(second)"); return }
    }

    /// `main.swift`'s claim is what `applicationWillTerminate` marks.
    @Test func aPrimaryClaimMarksItsLockExiting() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = GateSpy().gate(acquire: { LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory.url) }).claim()
        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }

        claim.markExiting()
        let second = withExtendedLifetime(claim) { LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url) }

        guard case .holderExiting = second else { Issue.record("expected .holderExiting, got \(second)"); return }
    }

    /// AppKit runs `applicationWillTerminate` ~50 ms after the quit is
    /// approved, so the mark goes on at approval: `.terminateNow` from
    /// `applicationShouldTerminate`, or `reply(toApplicationShouldTerminate:
    /// true)`. A later or cancelled quit may still not happen: no mark.
    @Test(arguments: [
        (NSApplication.TerminateReply.terminateNow, true),
        (.terminateLater, false),
        (.terminateCancel, false),
    ])
    func onlyAnApprovedQuitMarksTheLockExiting(reply: NSApplication.TerminateReply, marks: Bool) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = GateSpy().gate(acquire: { LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory.url) }).claim()
        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }

        let passedOn = claim.markingExiting(ifApproved: reply)
        let second = withExtendedLifetime(claim) { LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url) }

        #expect(passedOn == reply)
        switch (second, marks) {
        case (.holderExiting, true), (.busy, false): break
        default: Issue.record("marks=\(marks), got \(second)")
        }
    }

    @Test(arguments: [true, false])
    func onlyAnApprovingReplyMarksTheLockExiting(shouldTerminate: Bool) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = GateSpy().gate(acquire: { LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory.url) }).claim()
        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }

        let passedOn = claim.markingExiting(ifApproved: shouldTerminate)
        let second = withExtendedLifetime(claim) { LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url) }

        #expect(passedOn == shouldTerminate)
        switch (second, shouldTerminate) {
        case (.holderExiting, true), (.busy, false): break
        default: Issue.record("shouldTerminate=\(shouldTerminate), got \(second)")
        }
    }

    /// The next primary empties the file, so a mark left by a copy that has
    /// since exited never makes a later copy wait on a live one.
    @Test func aStaleExitingMarkIsClearedByTheNextPrimary() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let path = directory.path(LeoInstanceLock.fileName(for: Self.bundleID))
        var first: LeoInstanceLock? = try Self.heldLock(in: directory)
        #expect(first?.markExiting() == true)
        withExtendedLifetime(first) {}
        first = nil
        #expect(Self.fileSize(path) > 0, "the mark outlives the copy that wrote it")
        let second = try Self.heldLock(in: directory)

        let third = withExtendedLifetime(second) { LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url) }

        guard case .busy = third else { Issue.record("expected .busy, got \(third)"); return }
        #expect(Self.fileSize(path) == 0)
    }

    /// Only Leo's own mark, byte for byte, makes a copy wait.
    @Test(arguments: ["exiting", "exiting\nmore", "EXITING\n", "busy\n"])
    func anythingButTheExactMarkIsBusy(contents: String) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try Self.heldLock(in: directory)
        // In place, not replaced: the holder's lock stays on this very file.
        let writer = open(directory.path(LeoInstanceLock.fileName(for: Self.bundleID)), O_WRONLY | O_TRUNC | O_CLOEXEC)
        #expect(writer >= 0)
        #expect(Array(contents.utf8).withUnsafeBytes { write(writer, $0.baseAddress, $0.count) } == contents.utf8.count)
        close(writer)

        let second = withExtendedLifetime(holder) { LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url) }

        guard case .busy = second else { Issue.record("expected .busy, got \(second)"); return }
    }

    /// The wait is a real blocking `flock` (on an `O_NONBLOCK` descriptor):
    /// it hands over the lock only once the quitting holder lets it go.
    @Test func waitAndAcquireBlocksUntilTheHolderIsReleased() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = HeldLock(try Self.heldLock(in: directory))
        #expect(holder.markExiting())
        Thread {
            usleep(50_000) // let the waiter reach flock first
            holder.release()
        }.start()

        let attempt = LeoInstanceLock.waitAndAcquire(bundleIdentifier: Self.bundleID, in: directory.url)

        guard case .acquired = attempt else { Issue.record("expected .acquired, got \(attempt)"); return }
        #expect(holder.isReleased)
    }

    /// The wait checks the file exactly as `acquire` does, before blocking
    /// on it (a refusal returns at once, even while the file is locked).
    @Test func waitAndAcquireRefusesAnUnsafeLockFileWithoutWaiting() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let path = directory.path(LeoInstanceLock.fileName(for: Self.bundleID))
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(link(path, directory.path("other")) == 0)

        let attempt = LeoInstanceLock.waitAndAcquire(bundleIdentifier: Self.bundleID, in: directory.url)

        guard case .refused(let refusal) = attempt else { Issue.record("expected .refused, got \(attempt)"); return }
        #expect(refusal == LeoInstanceLockRefusal(error: .linked, path: path))
    }

    private static func acquired(_ attempt: LeoInstanceLockAttempt) -> LeoInstanceLock? {
        if case .acquired(let lock) = attempt { return lock }
        Issue.record("expected .acquired, got \(attempt)")
        return nil
    }

    /// A held lock on this suite's bundle ID in `directory`.
    private static func heldLock(in directory: LeoTestSocketDirectory) throws -> LeoInstanceLock {
        try #require(acquired(LeoInstanceLock.acquire(bundleIdentifier: bundleID, in: directory.url)))
    }

    private static func fileSize(_ path: String) -> Int64 {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 ? info.st_size : -1
    }
}

/// A lock handed to another thread, which drops it the way a quitting
/// copy's exit would.
private final class HeldLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var lock: LeoInstanceLock?
    private var released = false

    init(_ lock: LeoInstanceLock) { self.lock = lock }

    var isReleased: Bool { mutex.withLock { released } }

    func markExiting() -> Bool { mutex.withLock { lock?.markExiting() ?? false } }

    func release() {
        mutex.withLock {
            lock = nil
            released = true
        }
    }
}

/// Records what the gate asked the app to do instead of doing it.
private final class GateSpy {
    private(set) var activated: [String] = []
    private(set) var alerts: [LeoInstanceLockRefusal] = []
    private(set) var exits: [Int32] = []
    private(set) var waits: [String] = []

    func activate(_ bundleID: String) { activated.append(bundleID) }
    func alert(_ refusal: LeoInstanceLockRefusal) { alerts.append(refusal) }
    func exit(_ status: Int32) { exits.append(status) }

    /// Records the wait; the lock stays busy.
    func wait(_ bundleID: String) -> LeoInstanceLockAttempt {
        waits.append(bundleID)
        return .busy
    }

    func gate(
        isTestHost: Bool = false,
        acquire: @escaping (String) -> LeoInstanceLockAttempt,
        wait: ((String) -> LeoInstanceLockAttempt)? = nil
    ) -> LeoSingleInstance {
        LeoSingleInstance(
            bundleIdentifier: "studio.blackpaw.leo.macos.tests", isTestHost: isTestHost,
            acquireLock: acquire,
            waitForLock: { [self] bundleID in
                guard let wait else { return self.wait(bundleID) }
                waits.append(bundleID)
                return wait(bundleID)
            },
            activateOther: activate, alert: alert, terminate: exit
        )
    }
}

/// A throwaway app bundle laid out like the test host, with decoys:
/// `Contents/Info.plist`, `Contents/Resources/`, `Contents/Stray.xctest/`,
/// `Contents/PlugIns/{Plain,Nested/Deep}.xctest/`, and a second image
/// (`Helper`) beside the real plug-in's declared executable (`Tests`).
/// `symlinkedPlugIns` puts `Contents/PlugIns` elsewhere behind a symlink.
private struct FakeHostApp {
    static let plugIn = "Contents/PlugIns/Tests.xctest"
    static let injector = "/x/usr/lib/libXCTestBundleInject.dylib"
    let path: String
    var executable: String { path + "/Contents/MacOS/Fake" }
    var testExecutable: String { path + "/" + Self.plugIn + "/Contents/MacOS/Tests" }
    var helperImage: String { path + "/" + Self.plugIn + "/Contents/MacOS/Helper" }
    var strayExecutable: String { path + "/Contents/Stray.xctest/Contents/MacOS/Stray" }
    private var root: URL { URL(fileURLWithPath: path).deletingLastPathComponent() }

    init(symlinkedPlugIns: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leo-fake-host-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Fake.app")
        path = app.path
        let manager = FileManager.default
        let plugIns = symlinkedPlugIns ? root.appendingPathComponent("Elsewhere/PlugIns") : app.appendingPathComponent("Contents/PlugIns")
        for directory in [app.appendingPathComponent("Contents/MacOS"), app.appendingPathComponent("Contents/Resources"),
                          app.appendingPathComponent("Contents/Stray.xctest/Contents/MacOS"),
                          plugIns.appendingPathComponent("Tests.xctest/Contents/MacOS"), plugIns.appendingPathComponent("Plain.xctest"),
                          plugIns.appendingPathComponent("Nested/Deep.xctest/Contents/MacOS")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if symlinkedPlugIns {
            try manager.createSymbolicLink(at: app.appendingPathComponent("Contents/PlugIns"), withDestinationURL: plugIns)
        }
        for file in [app.appendingPathComponent("Contents/Info.plist"), app.appendingPathComponent("Contents/MacOS/Fake"),
                     app.appendingPathComponent("Contents/Stray.xctest/Contents/MacOS/Stray"),
                     plugIns.appendingPathComponent("Tests.xctest/Contents/MacOS/Tests"),
                     plugIns.appendingPathComponent("Tests.xctest/Contents/MacOS/Helper"),
                     plugIns.appendingPathComponent("Nested/Deep.xctest/Contents/MacOS/Deep")] {
            try Data().write(to: file)
        }
        let info: [String: Any] = ["CFBundleExecutable": "Tests", "CFBundlePackageType": "BNDL", "CFBundleIdentifier": "test.fake.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: plugIns.appendingPathComponent("Tests.xctest/Contents/Info.plist"))
    }

    /// As `xcodebuild test` launches the host.
    func isTestHost(_ testBundle: String, loadedImages: [String]? = nil) -> Bool {
        LeoSingleInstance.isTestHost(
            environment: ["XCInjectBundleInto": "unused", "XCTestBundlePath": testBundle],
            executablePath: executable, bundlePath: path,
            loadedImages: loadedImages ?? [Self.injector, testExecutable]
        )
    }

    /// As `-XCTest` with `XCInjectBundleInto` naming this executable.
    func isDirectTestHost(loadedImages: [String]? = nil) -> Bool {
        LeoSingleInstance.isTestHost(
            environment: ["XCInjectBundleInto": executable], executablePath: executable, bundlePath: path,
            loadedImages: loadedImages ?? [Self.injector, testExecutable]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
