import AppKit
import Darwin
import Foundation
import Testing

@testable import Ghostty

/// B-092: a copy launched while the previous copy quit found the lock still
/// held, yielded to the dying copy and exited, leaving no Leo. A quitting
/// holder now marks the lock with its pid; a new copy waits for that
/// process to end, then tries again -- never waiting on the lock itself, so
/// it never ends up queued, hidden, behind a live copy.
struct LeoSingleInstanceQuittingHolderTests {
    private typealias ClaimRun = LeoOffThread<LeoSingleInstance.Claim>
    private static let bundleID = LeoGateSpy.bundleID

    // MARK: - The mark

    @Test func aQuittingHolderKeepsTheLockAndNamesItsProcess() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try LeoInstanceLockTestFile.held(in: directory)

        try holder.markExiting()
        let second = withExtendedLifetime(holder) { LeoInstanceLockTestFile.acquire(in: directory) }

        guard case .holderExiting(let pid) = second else { Issue.record("expected .holderExiting, got \(second)"); return }
        #expect(pid == getpid())
        #expect(LeoInstanceLockTestFile.contents(in: directory) == "exiting \(getpid())\n")
    }

    @Test(arguments: [("exiting 1\n", 1), ("exiting 4242\n", 4242), ("exiting 2147483647\n", pid_t.max)] as [(String, pid_t)])
    func anExactMarkNamesItsProcess(contents: String, pid: pid_t) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try LeoInstanceLockTestFile.held(in: directory)
        LeoInstanceLockTestFile.overwrite(in: directory, with: contents)

        let second = withExtendedLifetime(holder) { LeoInstanceLockTestFile.acquire(in: directory) }

        guard case .holderExiting(let named) = second else { Issue.record("expected .holderExiting, got \(second)"); return }
        #expect(named == pid)
    }

    /// Strict and bounded: anything but an exact mark is a live holder.
    @Test(arguments: [
        "", "exiting\n", "exiting \n", "exiting 0\n", "exiting 012\n", "exiting -12\n", "exiting +12\n",
        "exiting 12", "exiting 12\nmore", "exiting 12x\n", "exiting 1 2\n", "EXITING 12\n", " exiting 12\n",
        "exiting 2147483648\n", "exiting 99999999999\n", "exiting 12\n" + String(repeating: " ", count: 40), "busy\n",
    ])
    func anythingButAnExactMarkIsALiveHolder(contents: String) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try LeoInstanceLockTestFile.held(in: directory)
        LeoInstanceLockTestFile.overwrite(in: directory, with: contents)

        let second = withExtendedLifetime(holder) { LeoInstanceLockTestFile.acquire(in: directory) }

        guard case .busy = second else { Issue.record("expected .busy, got \(second)"); return }
    }

    /// Marking again leaves exactly the new mark, not a longer one's tail.
    @Test func markingAgainLeavesExactlyTheNewMark() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try LeoInstanceLockTestFile.held(in: directory)

        try holder.markExiting(as: 123_456)
        try holder.markExiting(as: 7)

        #expect(LeoInstanceLockTestFile.contents(in: directory) == "exiting 7\n")
        withExtendedLifetime(holder) {}
    }

    /// A failed mark reports why (`Claim.markExiting` logs it).
    @Test func markingWithoutAHeldDescriptorThrows() {
        #expect(throws: LeoInstanceLockError.system(EBADF)) { try LeoInstanceLock(descriptor: -1).markExiting() }
    }

    /// The next primary empties the file, so a mark left by a copy that has
    /// since exited never makes a later copy wait.
    @Test func aStaleMarkIsClearedByTheNextPrimary() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        var first: LeoInstanceLock? = try LeoInstanceLockTestFile.held(in: directory)
        try first?.markExiting()
        withExtendedLifetime(first) {}
        first = nil
        #expect(LeoInstanceLockTestFile.contents(in: directory)?.isEmpty == false, "the mark outlives the copy that wrote it")
        let second = try LeoInstanceLockTestFile.held(in: directory)

        let third = withExtendedLifetime(second) { LeoInstanceLockTestFile.acquire(in: directory) }

        guard case .busy = third else { Issue.record("expected .busy, got \(third)"); return }
        #expect(LeoInstanceLockTestFile.contents(in: directory) == "")
    }

    // MARK: - Marking when the quit is approved

    /// `main.swift`'s claim is what the app delegate marks.
    @Test func aPrimaryClaimMarksItsLockExiting() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = Self.primaryClaim(in: directory)

        claim.markExiting()
        let second = withExtendedLifetime(claim) { LeoInstanceLockTestFile.acquire(in: directory) }

        guard case .holderExiting = second else { Issue.record("expected .holderExiting, got \(second)"); return }
    }

    /// AppKit runs `applicationWillTerminate` ~50 ms after the quit is
    /// approved, so the mark goes on at approval: `.terminateNow` from
    /// `applicationShouldTerminate`, or a deferred yes. A later or cancelled
    /// quit may still not happen: no mark.
    @Test(arguments: [
        (NSApplication.TerminateReply.terminateNow, true),
        (.terminateLater, false),
        (.terminateCancel, false),
    ])
    func onlyAnApprovedQuitMarksTheLockExiting(reply: NSApplication.TerminateReply, marks: Bool) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = Self.primaryClaim(in: directory)

        let passedOn = claim.markingExiting(ifApproved: reply)
        let second = withExtendedLifetime(claim) { LeoInstanceLockTestFile.acquire(in: directory) }

        #expect(passedOn == reply)
        #expect(Self.isMarked(second) == marks, "\(second)")
    }

    @Test(arguments: [true, false])
    func onlyAnApprovingReplyMarksTheLockExiting(shouldTerminate: Bool) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = Self.primaryClaim(in: directory)

        let passedOn = claim.markingExiting(ifApproved: shouldTerminate)
        let second = withExtendedLifetime(claim) { LeoInstanceLockTestFile.acquire(in: directory) }

        #expect(passedOn == shouldTerminate)
        #expect(Self.isMarked(second) == shouldTerminate, "\(second)")
    }

    /// A deferred answer's reply sees the lock already marked on a yes.
    @MainActor
    @Test(arguments: [true, false])
    func aDeferredYesIsMarkedBeforeItsReply(shouldTerminate: Bool) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let claim = Self.primaryClaim(in: directory)
        var replies: [(Bool, Bool)] = []

        claim.markingExiting(before: { replies.append(($0, Self.isMarked(LeoInstanceLockTestFile.acquire(in: directory)))) })(shouldTerminate)

        #expect(replies.map(\.0) == [shouldTerminate])
        #expect(replies.map(\.1) == [shouldTerminate], "marked when replying")
        withExtendedLifetime(claim) {}
    }

    // MARK: - Waiting out a quitting holder

    /// The reported case: the holder is quitting, so this copy waits for its
    /// process to end (dropping `quitting` stands in for that), tries again
    /// and carries on as the primary.
    @Test func aCopyLaunchedWhileTheHolderIsQuittingTakesOverInsteadOfQuitting() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let quitting = try Self.quittingHolder(in: directory)
        let spy = LeoGateSpy()
        let gate = spy.gate(acquire: { _ in LeoInstanceLockTestFile.acquire(in: directory) }, onWait: { _ in quitting.drop() })

        let claim = ClaimRun.run({ gate.claim() })

        guard case .primary? = claim else { Issue.record("expected .primary, got \(String(describing: claim))"); return }
        #expect(spy.waits == [getpid()])
        #expect(spy.exits.isEmpty)
        #expect(spy.activated.isEmpty)
        #expect(spy.alerts.isEmpty)
    }

    /// The kernel reports a quitting copy gone (so the real wait returns at
    /// once) a moment before it lets go of its lock: 300 of 300 exits in a C
    /// probe, and 1 of 8 real launch/quit races left no Leo. A try in that
    /// moment finds the same mark, so this copy gives it a moment and takes
    /// over instead of yielding to a copy that's about to be gone.
    @Test func aCopyWaitedOutThatStillHoldsItsLockIsGivenAMoment() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let quitting = try Self.quittingHolder(in: directory)
        let spy = LeoGateSpy()
        let gate = spy.gate(acquire: { _ in LeoInstanceLockTestFile.acquire(in: directory) }, onPause: {
            if spy.pauses == 3 { quitting.drop() }
        })

        let claim = ClaimRun.run({ gate.claim() })

        guard case .primary? = claim else { Issue.record("expected .primary, got \(String(describing: claim))"); return }
        #expect(spy.waits == [getpid()])
        #expect(spy.pauses == 3)
        #expect(spy.exits.isEmpty)
    }

    /// D-051 still holds: a live holder that isn't quitting is activated and
    /// this copy exits 0 without waiting.
    @Test func aLiveHolderWithoutTheMarkIsStillYieldedTo() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let holder = try LeoInstanceLockTestFile.held(in: directory)
        let spy = LeoGateSpy()

        let claim = withExtendedLifetime(holder) { spy.gate(acquire: { _ in LeoInstanceLockTestFile.acquire(in: directory) }).claim() }

        guard case .yielded = claim else { Issue.record("expected .yielded, got \(claim)"); return }
        #expect(spy.exits == [0])
        #expect(spy.activated == [Self.bundleID])
        #expect(spy.waits.isEmpty)
    }

    /// Two copies launched while one quits both wait for it. Once it's gone
    /// exactly one becomes Leo and the other yields to it (D-051), rather
    /// than waiting, hidden, to take over when the new Leo quits.
    @Test func twoCopiesWaitingOnOneQuittingHolderLeaveExactlyOnePrimary() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let quitting = try Self.quittingHolder(in: directory)
        let (firstSpy, secondSpy) = (LeoGateSpy(), LeoGateSpy())
        let second = LeoHeld<LeoSingleInstance.Claim>()
        let acquire = { (_: String) in LeoInstanceLockTestFile.acquire(in: directory) }
        let secondGate = secondSpy.gate(acquire: acquire, onWait: { _ in quitting.drop() })
        // The second copy starts waiting while the first is: both are waiting
        // when the quitting copy's process ends.
        let firstGate = firstSpy.gate(acquire: acquire, onWait: { _ in second.set(secondGate.claim()) })

        let first = ClaimRun.run({ firstGate.claim() }, unblock: second.drop)

        #expect(second.read(Self.isPrimary), "the second copy became Leo")
        guard case .yielded? = first else { Issue.record("expected the first copy to yield, got \(String(describing: first))"); return }
        #expect(firstSpy.exits == [0])
        #expect(firstSpy.activated == [Self.bundleID])
        #expect(firstSpy.waits == [getpid()])
        #expect(secondSpy.waits == [getpid()])
        #expect(secondSpy.exits.isEmpty)
    }

    /// The quitting copy is gone but another copy took the lock, unmarked,
    /// before this one tried again: that's a live Leo, so this one yields.
    @Test func aCopyThatTookTheLockDuringTheWaitIsYieldedTo() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let quitting = try Self.quittingHolder(in: directory)
        let third = LeoHeld<LeoInstanceLock>()
        let spy = LeoGateSpy()
        let gate = spy.gate(acquire: { _ in LeoInstanceLockTestFile.acquire(in: directory) }, onWait: { _ in
            quitting.drop()
            if case .acquired(let lock) = LeoInstanceLockTestFile.acquire(in: directory) { third.set(lock) }
        })

        let claim = ClaimRun.run({ gate.claim() }, unblock: third.drop)

        guard case .yielded? = claim else { Issue.record("expected .yielded, got \(String(describing: claim))"); return }
        #expect(spy.exits == [0])
        #expect(spy.activated == [Self.bundleID])
        #expect(third.holds, "the copy that took the lock keeps it")
    }

    /// What a mark can name that `waitForExit` turns down before asking
    /// whether it's a copy of this bundle (that check is stood in for here;
    /// see the B-118 tests below for a live program that isn't one).
    enum Leftover: CaseIterable {
        /// A copy that has exited.
        case gone
        /// A reused pid: not a copy that could hold our 0600 lock.
        case anotherUsers
        case thisProcess
    }

    /// A live holder's file still names a copy that can't be holding it --
    /// between the new holder's flock and its truncate, or under an older
    /// build that never empties the file. The real wait returns at once, the
    /// tries after it keep finding the same mark, and after a bounded moment
    /// this copy yields: no blocking, no endless loop.
    @Test(arguments: Leftover.allCases)
    func aLeftoverMarkOnALiveHolderIsYieldedTo(_ leftover: Leftover) throws {
        try Self.expectALeftoverMarkIsYieldedTo(naming: try Self.pid(of: leftover), isCopy: { _ in true })
    }

    // MARK: - Waiting for a process to exit

    /// A real kqueue wait on a copy of this bundle -- nothing a test can
    /// spawn is one, so the check is stood in for: it's asked about that
    /// process, and the wait returns only once the process has exited.
    @Test func waitForExitStillWaitsOnACopyOfThisBundle() throws {
        let pid = try LeoTestProcess.spawn("/bin/sleep", ["1"])
        #expect(kill(pid, 0) == 0, "running before the wait")
        let asked = LeoHeld<pid_t>()

        let returned = LeoOffThread<Bool>.run({
            LeoInstanceLock.waitForExit(of: pid, isCopy: { asked.set($0); return true })
            return true
        })

        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        let code = errno
        #expect(returned == true)
        #expect(reaped == pid || (reaped == -1 && code == ECHILD), "exited by the time the wait returned (waitpid=\(reaped))")
        #expect(asked.read { $0 } == pid, "asked whether it's a copy")
        if reaped == 0 { _ = waitpid(pid, &status, 0) }
    }

    /// Nothing to wait for: gone, this very process, or another user's.
    @Test(arguments: Leftover.allCases)
    func waitForExitReturnsAtOnceWhenThereIsNothingToWaitFor(_ leftover: Leftover) throws {
        let pid = try Self.pid(of: leftover)

        let returned = LeoOffThread<Bool>.run({ LeoInstanceLock.waitForExit(of: pid, isCopy: { _ in true }); return true })

        #expect(returned == true)
    }

    // MARK: - Only a copy of this bundle is waited on (B-118)

    /// A mark's pid can have been reused by a live process of this user's
    /// that isn't Leo at all and may run for hours: never waited on.
    @Test func waitForExitDoesNotWaitOnALiveSameUserProcessThatIsNotThisBundle() throws {
        let other = try LeoTestChild("/bin/sleep", ["60"])
        defer { other.stop() }

        let returned = LeoOffThread<Bool>.run({ LeoInstanceLock.waitForExit(of: other.pid, isCopy: Self.isACopy); return true }, unblock: other.stop)

        #expect(returned == true)
        #expect(other.isRunning, "returned while it was still running")
    }

    /// The real gate checks for a copy of this app's own bundle.
    @Test func theLiveGateDoesNotWaitOnAnotherProgram() throws {
        let other = try LeoTestChild("/bin/sleep", ["60"])
        defer { other.stop() }
        let gate = LeoSingleInstance.live()

        let returned = LeoOffThread<Bool>.run({ gate.waitForExit(other.pid); return true }, unblock: other.stop)

        #expect(returned == true)
        #expect(other.isRunning, "returned while it was still running")
    }

    /// A live holder whose file names that other program is given the
    /// release moment and yielded to (D-051), as for any leftover mark.
    @Test func aMarkNamingAnotherLiveProgramIsYieldedToAfterTheReleaseMoment() throws {
        let other = try LeoTestChild("/bin/sleep", ["60"])
        defer { other.stop() }

        try Self.expectALeftoverMarkIsYieldedTo(naming: other.pid, isCopy: Self.isACopy, unblock: other.stop)

        #expect(other.isRunning, "never waited for it to end")
    }

    /// What `proc_pidpath` could name, against a fake bundle declaring the
    /// tests' bundle ID with main executable `foo`.
    enum Executable: CaseIterable {
        case mainExecutable
        case anotherBundlesExecutable
        /// Not `CFBundleExecutable`: another executable in `Contents/MacOS`.
        case helperExecutable
        case noInfoPlist
        case infoPlistNotAPlist
        /// Must not block the launch.
        case infoPlistIsAFIFO
        case infoPlistIsADirectory
        case oversizedInfoPlist
        case notInContentsMacOS
        case notInAnApp
        case systemTool
        /// `proc_pidpath` failed.
        case unknown

        var isMainExecutable: Bool { self == .mainExecutable }

        func path(in directory: LeoTestSocketDirectory) throws -> String? {
            let identifier = LeoGateSpy.bundleID
            let declared = LeoTestBundle.InfoPlist.declaring(identifier: identifier, executable: "foo")
            switch self {
            case .mainExecutable: return try LeoTestBundle(in: directory, infoPlist: declared).executable()
            case .anotherBundlesExecutable:
                return try LeoTestBundle(in: directory, infoPlist: .declaring(identifier: "studio.blackpaw.other", executable: "foo")).executable()
            case .helperExecutable: return try LeoTestBundle(in: directory, infoPlist: declared, executables: ["foo", "helper"]).executable("helper")
            case .noInfoPlist: return try LeoTestBundle(in: directory, infoPlist: .missing).executable()
            case .infoPlistNotAPlist: return try LeoTestBundle(in: directory, infoPlist: .contents(Data("not a plist".utf8))).executable()
            case .infoPlistIsAFIFO: return try LeoTestBundle(in: directory, infoPlist: .fifo).executable()
            case .infoPlistIsADirectory: return try LeoTestBundle(in: directory, infoPlist: .directory).executable()
            case .oversizedInfoPlist:
                let padding = ["LeoPadding": String(repeating: "x", count: LeoInstanceLock.maxInfoPlistBytes)]
                let plist = try LeoTestBundle.plist(identifier: identifier, executable: "foo", extra: padding)
                return try LeoTestBundle(in: directory, infoPlist: .contents(plist)).executable()
            case .notInContentsMacOS: return try LeoTestBundle(in: directory, infoPlist: declared).path("Contents/Resources/foo")
            case .notInAnApp: return try LeoTestBundle(in: directory, name: "Foo", infoPlist: declared).executable()
            case .systemTool: return "/bin/sleep"
            case .unknown: return nil
            }
        }
    }

    /// Only `<X>.app/Contents/MacOS/<exe>`, where `X.app` declares the bundle
    /// ID and `<exe>` as its `CFBundleExecutable`, is a copy's executable.
    @Test(arguments: Executable.allCases)
    func isMainExecutableOfBundle(_ executable: Executable) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let path = try executable.path(in: directory)

        // Off this thread: a read that blocks is recorded, then ended by
        // opening a FIFO's other end.
        let isMain = LeoOffThread<Bool>.run(
            { LeoInstanceLock.isMainExecutable(path, ofBundle: Self.bundleID) },
            unblock: { Self.openOtherEnd(of: directory.path("Foo.app/Contents/Info.plist")) }
        )

        #expect(isMain == executable.isMainExecutable)
    }

    /// Real `proc_pidpath` on the test host, the debug Leo.app.
    @Test func thisTestHostIsACopyOfItsOwnBundle() throws {
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let executable = try #require(Bundle.main.executablePath.flatMap(Self.realPath))

        #expect(LeoInstanceLock.executablePath(of: getpid()).flatMap(Self.realPath) == executable)
        #expect(LeoInstanceLock.isCopy(getpid(), of: identifier))
        #expect(!LeoInstanceLock.isCopy(getpid(), of: Self.bundleID))
    }

    @Test func isCopyIsFalseForAGonePid() throws {
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let pid = try LeoTestProcess.gone()

        #expect(LeoInstanceLock.executablePath(of: pid) == nil)
        #expect(!LeoInstanceLock.isCopy(pid, of: identifier))
    }

    // MARK: - Helpers

    /// A held lock marked exiting (naming this process), boxed so that
    /// dropping it stands in for that copy's process ending.
    private static func quittingHolder(in directory: LeoTestSocketDirectory) throws -> LeoHeld<LeoInstanceLock> {
        let lock = try LeoInstanceLockTestFile.held(in: directory)
        try lock.markExiting()
        return LeoHeld(lock)
    }

    /// A live holder's file names `named`: with the real wait (asking
    /// `isCopy`), this copy gives it the release moment and yields to it,
    /// never blocking.
    private static func expectALeftoverMarkIsYieldedTo(
        naming named: pid_t, isCopy: @escaping (pid_t) -> Bool, unblock: () -> Void = {}
    ) throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let live = LeoHeld(try LeoInstanceLockTestFile.held(in: directory))
        LeoInstanceLockTestFile.overwrite(in: directory, with: "exiting \(named)\n")
        let spy = LeoGateSpy()
        let gate = spy.gate(
            acquire: { _ in LeoInstanceLockTestFile.acquire(in: directory) },
            onWait: { LeoInstanceLock.waitForExit(of: $0, isCopy: isCopy) }
        )

        let claim = ClaimRun.run({ gate.claim() }, unblock: {
            live.drop()
            unblock()
        })

        guard case .yielded? = claim else { Issue.record("expected .yielded, got \(String(describing: claim))"); return }
        #expect(spy.waits == [named])
        #expect(spy.pauses == LeoSingleInstance.maxReleasePauses)
        #expect(spy.exits == [0])
        #expect(live.holds)
    }

    /// The real check, for the tests' bundle ID: nothing running is a copy.
    private static func isACopy(_ pid: pid_t) -> Bool {
        LeoInstanceLock.isCopy(pid, of: bundleID)
    }

    /// Opens and closes the write end of the FIFO at `path`, if there is
    /// one, so a reader blocked opening it carries on (and reads nothing).
    private static func openOtherEnd(of path: String) {
        let writer = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if writer >= 0 { close(writer) }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func pid(of leftover: Leftover) throws -> pid_t {
        switch leftover {
        case .gone: return try LeoTestProcess.gone()
        case .anotherUsers: return 1
        case .thisProcess: return getpid()
        }
    }

    private static func primaryClaim(in directory: LeoTestSocketDirectory) -> LeoSingleInstance.Claim {
        let claim = LeoGateSpy().gate(acquire: { _ in LeoInstanceLockTestFile.acquire(in: directory) }).claim()
        if case .primary = claim { return claim }
        Issue.record("expected .primary, got \(claim)")
        return claim
    }

    private static func isMarked(_ attempt: LeoInstanceLockAttempt) -> Bool {
        if case .holderExiting = attempt { return true }
        return false
    }

    private static func isPrimary(_ claim: LeoSingleInstance.Claim?) -> Bool {
        if case .primary? = claim { return true }
        return false
    }
}
