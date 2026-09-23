import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Leo is single-instance per bundle ID (D-051): a second copy of the same
/// bundle activates the first and quits before any tunnel state is touched.
struct LeoSingleInstanceTests {
    private static let bundleID = "studio.blackpaw.leo.macos.tests"

    // MARK: - Decision

    @Test func acquiredLockContinuesLaunching() {
        var activated: [String] = []
        var terminations = 0
        let gate = gate(acquire: { _ in .acquired(LeoInstanceLock(descriptor: -1)) },
                        activated: { activated.append($0) }, terminated: { terminations += 1 })

        let claim = gate.claim()

        guard case .primary = claim else { Issue.record("expected .primary, got \(claim)"); return }
        #expect(activated.isEmpty)
        #expect(terminations == 0)
    }

    @Test func busyLockActivatesTheOtherCopyAndTerminates() {
        var activated: [String] = []
        var terminations = 0
        let gate = gate(acquire: { _ in .busy }, activated: { activated.append($0) }, terminated: { terminations += 1 })

        let claim = gate.claim()

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(activated == [Self.bundleID])
        #expect(terminations == 1)
    }

    @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto"])
    func aTestHostNeverTakesTheLockOrQuits(variable: String) {
        var attempts = 0
        var terminations = 0
        let gate = gate(environment: [variable: "/x"], acquire: { _ in attempts += 1; return .busy },
                        activated: { _ in }, terminated: { terminations += 1 })

        let claim = gate.claim()

        guard case .skipped = claim else { Issue.record("expected .skipped, got \(claim)"); return }
        #expect(attempts == 0)
        #expect(terminations == 0)
    }

    /// This very suite runs hosted in the debug Leo.app, which must not
    /// have quit (or taken the lock) whether or not a debug copy is running.
    @Test func theRealEnvironmentOfThisTestRunIsATestHost() {
        #expect(LeoSingleInstance.isTestHost(ProcessInfo.processInfo.environment))
    }

    @Test func aRefusedLockFailsOpen() {
        var terminations = 0
        let gate = gate(acquire: { _ in .refused(LeoInstanceLockError.notOwned) },
                        activated: { _ in Issue.record("must not activate") }, terminated: { terminations += 1 })

        let claim = gate.claim()

        guard case .failedOpen = claim else { Issue.record("expected .failedOpen, got \(claim)"); return }
        #expect(terminations == 0)
    }

    @Test func aMissingBundleIdentifierSkips() {
        let gate = LeoSingleInstance(
            bundleIdentifier: nil, environment: [:],
            acquireLock: { _ in Issue.record("must not lock"); return .busy },
            activateOther: { _ in }, terminate: { Issue.record("must not quit") }
        )

        guard case .skipped = gate.claim() else { Issue.record("expected .skipped"); return }
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

    @Test func aSymlinkAtTheLockPathIsRefusedAndNotFollowed() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let target = directory.path("target")
        let path = directory.path(LeoInstanceLock.fileName(for: Self.bundleID))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        let attempt = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url)

        guard case .refused = attempt else { Issue.record("expected .refused, got \(attempt)"); return }
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func aHardLinkedLockFileIsRefused() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let path = directory.path(LeoInstanceLock.fileName(for: Self.bundleID))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        #expect(link(path, directory.path("other")) == 0)

        let attempt = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url)

        guard case .refused = attempt else { Issue.record("expected .refused, got \(attempt)"); return }
    }

    @Test func aLockFileAnotherUserOwnsIsRefused() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }

        let attempt = LeoInstanceLock.acquire(bundleIdentifier: Self.bundleID, in: directory.url, owner: geteuid() + 1)

        guard case .refused = attempt else { Issue.record("expected .refused, got \(attempt)"); return }
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

    // MARK: - Helpers

    private func gate(
        environment: [String: String] = [:],
        acquire: @escaping (String) -> LeoInstanceLockAttempt,
        activated: @escaping (String) -> Void,
        terminated: @escaping () -> Void
    ) -> LeoSingleInstance {
        LeoSingleInstance(
            bundleIdentifier: Self.bundleID, environment: environment,
            acquireLock: acquire, activateOther: activated, terminate: terminated
        )
    }

    private static func acquired(_ attempt: LeoInstanceLockAttempt) -> LeoInstanceLock? {
        if case .acquired(let lock) = attempt { return lock }
        Issue.record("expected .acquired, got \(attempt)")
        return nil
    }
}
