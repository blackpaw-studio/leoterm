import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Leo is single-instance per bundle ID (D-051): a second copy of the same
/// bundle activates the first and quits before any tunnel state is touched,
/// and a lock that can't be taken safely stops the launch (fails closed).
struct LeoSingleInstanceTests {
    private static let bundleID = LeoGateSpy.bundleID

    // MARK: - Decision

    @Test func acquiredLockContinuesLaunching() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: { _ in .acquired(LeoInstanceLock(descriptor: -1)) }).claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.activated.isEmpty)
        #expect(spy.alerts.isEmpty)
        #expect(spy.exits.isEmpty)
    }

    @Test func busyLockActivatesTheOtherCopyAndExitsCleanly() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: { _ in .busy }).claim()

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.alerts.isEmpty)
        #expect(spy.exits == [0])
        #expect(spy.waits.isEmpty)
    }

    /// B-092: the holder is quitting (it marked the lock with its pid when
    /// its quit was approved), so this copy waits for that process to end,
    /// tries again, and carries on as the primary.
    @Test func anExitingHolderIsWaitedOutNotYieldedTo() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: Self.answering([.holderExiting(42), .acquired(LeoInstanceLock(descriptor: -1))])).claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.waits == [42])
        #expect(spy.activated.isEmpty)
        #expect(spy.alerts.isEmpty)
        #expect(spy.exits.isEmpty)
    }

    /// The next try settles like a first one: busy still yields (D-051) ...
    @Test func aTryAfterTheWaitThatIsBusyStillYields() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: Self.answering([.holderExiting(42), .busy])).claim()

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.waits == [42])
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.exits == [0])
    }

    /// ... and a refusal still alerts and quits non-zero (D-053).
    @Test func aRefusedTryAfterTheWaitAlertsAndQuitsNonZero() {
        let spy = LeoGateSpy()
        let refusal = LeoInstanceLockRefusal(error: .linked, path: "/c/leo/x.instance.lock")

        let claim = spy.gate(acquire: Self.answering([.holderExiting(42), .refused(refusal)])).claim()

        guard case .refused = claim else { Issue.record("expected .refused, got \(claim)"); return }
        #expect(spy.alerts == [refusal])
        #expect(spy.exits == [1])
        #expect(spy.activated.isEmpty)
    }

    /// A copy that took the lock during the wait and is itself quitting by
    /// the next try is waited out in turn.
    @Test func eachNewlyQuittingHolderIsWaitedOut() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: Self.answering([.holderExiting(42), .holderExiting(43), .acquired(LeoInstanceLock(descriptor: -1))])).claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.waits == [42, 43])
        #expect(spy.exits.isEmpty)
    }

    /// XNU reports a quitting copy gone (the wait returns at once) a moment
    /// before it releases its lock, so the next try can find the same mark.
    /// Give it that moment: the real launch/quit race otherwise left no Leo.
    @Test func aCopyWaitedOutThatStillHoldsItsLockIsGivenAMoment() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: Self.answering([
            .holderExiting(42), .holderExiting(42), .holderExiting(42), .acquired(LeoInstanceLock(descriptor: -1)),
        ])).claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(spy.waits == [42])
        #expect(spy.pauses == 2)
        #expect(spy.exits.isEmpty)
    }

    /// Still marked by a copy already waited out, long after it's gone: a
    /// live copy holds the lock and never cleared the mark (an older build).
    /// Yield to it after a bounded moment: never wait again, never block.
    @Test func aMarkNamingACopyAlreadyWaitedOutIsALiveHolderInTheEnd() {
        let spy = LeoGateSpy()

        let claim = spy.gate(acquire: Self.answering([.holderExiting(42)])).claim()

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.waits == [42])
        #expect(spy.pauses == LeoSingleInstance.maxReleasePauses)
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.exits == [0])
    }

    @Test func aTestHostNeverTakesTheLockOrQuits() {
        let spy = LeoGateSpy()
        var attempts = 0

        let claim = spy.gate(isTestHost: true, acquire: { _ in attempts += 1; return .busy }).claim()

        guard case .skipped = claim else { Issue.record("expected .skipped, got \(claim)"); return }
        #expect(attempts == 0)
        #expect(spy.exits.isEmpty)
    }

    /// Fails closed: a lock that can't be taken safely means another copy
    /// might be running unseen, so this one explains why and quits non-zero.
    @Test func aRefusedLockAlertsAndQuitsNonZero() {
        let spy = LeoGateSpy()
        let refusal = LeoInstanceLockRefusal(error: .notOwned, path: "/c/leo/x.instance.lock")

        let claim = spy.gate(acquire: { _ in .refused(refusal) }).claim()

        guard case .refused = claim else { Issue.record("expected .refused, got \(claim)"); return }
        #expect(spy.alerts == [refusal])
        #expect(spy.exits == [1])
        #expect(spy.activated.isEmpty)
    }

    /// No bundle ID, no bundle-keyed shared state to protect: launch.
    @Test func aMissingBundleIdentifierSkips() {
        let spy = LeoGateSpy()
        let gate = LeoSingleInstance(
            bundleIdentifier: nil, isTestHost: false,
            acquireLock: { _ in Issue.record("must not lock"); return .busy }, waitForExit: spy.waitForExit, pauseForRelease: spy.pauseForRelease,
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
        let spy = LeoGateSpy()
        let gate = LeoSingleInstance(
            bundleIdentifier: bundleID, isTestHost: false,
            acquireLock: { [directory, owner] in LeoInstanceLock.acquire(bundleIdentifier: $0, in: directory, owner: owner) },
            waitForExit: spy.waitForExit, pauseForRelease: spy.pauseForRelease, activateOther: spy.activate, alert: spy.alert, terminate: spy.exit
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

    private static func acquired(_ attempt: LeoInstanceLockAttempt) -> LeoInstanceLock? {
        if case .acquired(let lock) = attempt { return lock }
        Issue.record("expected .acquired, got \(attempt)")
        return nil
    }

    /// Answers each attempt with the next of `attempts`, then the last again.
    private static func answering(_ attempts: [LeoInstanceLockAttempt]) -> (String) -> LeoInstanceLockAttempt {
        var remaining = attempts[...]
        return { _ in remaining.count > 1 ? remaining.removeFirst() : remaining[remaining.startIndex] }
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
