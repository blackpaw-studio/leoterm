import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The dragged chat width: one value shared by every window, stored in
/// `UserDefaults` the way the sidebar's width is.
/// Yields to the main actor until `condition` holds or a guard expires, so the
/// observer's asynchronous hop to main has run; a timeout fails the caller's
/// next expectation rather than hanging.
@MainActor
private func settleOnMain(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { await Task.yield() }
}

@MainActor
struct LeoChatWidthPreferenceTests {
    @Test func startsWithNoPreference() {
        #expect(LeoWindowSession(defaults: LeoInMemoryDefaults()).preferredChatWidth == nil)
    }

    @Test func preferencePersistsAcrossSessionsSharingDefaults() {
        let defaults = LeoInMemoryDefaults()
        LeoWindowSession(defaults: defaults).setPreferredChatWidth(612)
        #expect(defaults.double(forKey: LeoWindowSession.chatWidthKey) == 612)
        #expect(LeoWindowSession(defaults: defaults).preferredChatWidth == 612)
    }

    @Test func resetClearsTheStoredPreference() {
        let defaults = LeoInMemoryDefaults()
        let session = LeoWindowSession(defaults: defaults)
        session.setPreferredChatWidth(612)
        session.resetPreferredChatWidth()
        #expect(session.preferredChatWidth == nil)
        #expect(defaults.object(forKey: LeoWindowSession.chatWidthKey) == nil)
        #expect(LeoWindowSession(defaults: defaults).preferredChatWidth == nil)
    }

    @Test func aChangeInOneWindowReachesTheOthers() async {
        let defaults = LeoInMemoryDefaults()
        let first = LeoWindowSession(defaults: defaults)
        let second = LeoWindowSession(defaults: defaults)
        first.setPreferredChatWidth(640)
        // `LeoInMemoryDefaults` never posts this; the real store does on every write.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await settleOnMain { second.preferredChatWidth == 640 }
        #expect(second.preferredChatWidth == 640)
        first.resetPreferredChatWidth()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await settleOnMain { second.preferredChatWidth == nil }
        #expect(second.preferredChatWidth == nil)
    }

    @Test func sessionHandsItsPreferenceToTheLayoutMath() {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.setPreferredChatWidth(700)
        #expect(session.chatWidth(for: .sideBySide, contentWidth: 1600) == 700)
        session.resetPreferredChatWidth()
        #expect(session.chatWidth(for: .sideBySide, contentWidth: 1600) == LeoChatLayout.sideBySide.chatWidth(in: 1600))
    }
}

/// Quitting hung for minutes: a background writer posts
/// `UserDefaults.didChangeNotification` synchronously, and an observer
/// registered with `queue: .main` makes the poster wait for the main thread --
/// which was itself waiting on that writer. A write from another thread must
/// never depend on the main thread running.
@MainActor
struct LeoChatWidthObserverDeadlockTests {
    private static let guardSeconds = 3.0

    @Test func backgroundWriteCompletesWhileMainIsBlockedWaitingOnIt() async {
        let defaults = LeoInMemoryDefaults(postsChangeNotifications: true)
        let session = LeoWindowSession(defaults: defaults)
        let written = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defaults.set(Double(640), forKey: LeoWindowSession.chatWidthKey)
            written.signal()
        }

        // Main blocks here exactly as `applicationWillTerminate` does.
        #expect(written.wait(timeout: .now() + Self.guardSeconds) == .success)
        await settleOnMain { session.preferredChatWidth == 640 }
        #expect(session.preferredChatWidth == 640)
    }
}
