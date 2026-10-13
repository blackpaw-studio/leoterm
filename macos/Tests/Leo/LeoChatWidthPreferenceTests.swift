import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The dragged chat width: one value shared by every window, stored in
/// `UserDefaults` the way the sidebar's width is.
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

    @Test func aChangeInOneWindowReachesTheOthers() {
        let defaults = LeoInMemoryDefaults()
        let first = LeoWindowSession(defaults: defaults)
        let second = LeoWindowSession(defaults: defaults)
        first.setPreferredChatWidth(640)
        // `LeoInMemoryDefaults` never posts this; the real store does on every write.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(second.preferredChatWidth == 640)
        first.resetPreferredChatWidth()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
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
