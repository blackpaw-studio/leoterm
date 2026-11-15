import Combine
import Testing

@testable import Ghostty
@testable import LeoKit

/// E4: a sidebar row shows a globe while its agent has a browser.
@MainActor
struct LeoAgentRowBrowserBadgeTests {
    private let presence = FakePresence()

    private func badges() -> LeoAgentBrowserBadges { LeoAgentBrowserBadges(presence: presence) }

    @Test
    func shownOnlyWhileTheAgentHasABrowser() {
        let badges = badges()
        #expect(!badges.isShown(host: .local, agent: "alpha", dispatchID: nil))

        presence.open(LeoAgentBrowserKey(host: .local, agent: "alpha"))
        #expect(badges.isShown(host: .local, agent: "alpha", dispatchID: nil))
        #expect(!badges.isShown(host: .local, agent: "beta", dispatchID: nil))

        presence.remove(LeoAgentBrowserKey(host: .local, agent: "alpha"))
        #expect(!badges.isShown(host: .local, agent: "alpha", dispatchID: nil))
    }

    @Test
    func browsersOnOtherMachinesDoNotCount() {
        let badges = badges()
        presence.open(LeoAgentBrowserKey(host: .remote("dionysus"), agent: "alpha"))

        #expect(!badges.isShown(host: .local, agent: "alpha", dispatchID: nil))
        #expect(badges.isShown(host: .remote("dionysus"), agent: "alpha", dispatchID: nil))
    }

    @Test
    func dispatchRowsMapToTheirOwnBrowser() {
        let badges = badges()
        presence.open(.dispatch(host: .local, id: "d1"))

        #expect(badges.isShown(host: .local, agent: "alpha", dispatchID: "d1"))
        #expect(!badges.isShown(host: .local, agent: "alpha", dispatchID: nil), "the parent agent's row has no browser of its own")
        #expect(!badges.isShown(host: .local, agent: "alpha", dispatchID: "d2"))
    }

    @Test
    func startsWithBrowsersThatAlreadyExist() {
        presence.open(LeoAgentBrowserKey(host: .local, agent: "alpha"))

        #expect(badges().isShown(host: .local, agent: "alpha", dispatchID: nil))
    }

    @Test
    func announcesChangesToTheRows() {
        let badges = badges()
        var announced = 0
        let subscription = badges.objectWillChange.sink { announced += 1 }

        presence.open(LeoAgentBrowserKey(host: .local, agent: "alpha"))
        presence.remove(LeoAgentBrowserKey(host: .local, agent: "alpha"))

        #expect(announced == 2)
        subscription.cancel()
    }
}
