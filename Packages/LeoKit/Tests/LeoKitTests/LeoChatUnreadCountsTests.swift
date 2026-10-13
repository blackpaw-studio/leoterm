import Foundation
import Testing

@testable import LeoKit

struct LeoChatUnreadCountsTests {
    static let zeus = LeoAgentID(host: .local, name: "zeus")
    static let hera = LeoAgentID(host: .local, name: "hera")
    static let remoteZeus = LeoAgentID(host: .remote("box"), name: "zeus")

    static func message(
        _ agent: String, _ direction: LeoChatMessage.Direction = .outbound, kind: LeoChatMessage.Kind = .text
    ) -> LeoChatMessage {
        LeoChatMessage(id: UUID().uuidString, agent: agent, direction: direction, kind: kind, text: "hi", ts: Date(timeIntervalSince1970: 0))
    }

    static let seeded = LeoChatUnreadCounts().seeding(
        [LeoChatThread(agent: "zeus", unread: 3), LeoChatThread(agent: "hera", unread: 1)], host: .local
    )

    @Test func seedSetsEachAgentsCount() {
        #expect(Self.seeded[Self.zeus] == 3)
        #expect(Self.seeded[Self.hera] == 1)
        #expect(Self.seeded[LeoAgentID(host: .local, name: "ares")] == 0)
    }

    @Test func anAgentMessageAddsOne() {
        let counts = Self.seeded.receiving(.message(Self.message("zeus")), host: .local, isOnScreen: false)
        #expect(counts[Self.zeus] == 4)
        #expect(counts[Self.hera] == 1)
    }

    @Test func aFirstMessageStartsAtOne() {
        let counts = LeoChatUnreadCounts().receiving(.message(Self.message("zeus")), host: .local, isOnScreen: false)
        #expect(counts[Self.zeus] == 1)
    }

    @Test func yourOwnMessageIsIgnored() {
        let counts = Self.seeded.receiving(.message(Self.message("zeus", .inbound)), host: .local, isOnScreen: false)
        #expect(counts == Self.seeded)
    }

    @Test func anUpdateIsIgnored() {
        let counts = Self.seeded.receiving(.updated(Self.message("zeus")), host: .local, isOnScreen: false)
        #expect(counts == Self.seeded)
    }

    @Test func anOnScreenMessageIsSuppressed() {
        let counts = Self.seeded.receiving(.message(Self.message("zeus")), host: .local, isOnScreen: true)
        #expect(counts == Self.seeded)
    }

    @Test func clearingZeroesOneAgent() {
        let counts = Self.seeded.clearing(Self.zeus)
        #expect(counts[Self.zeus] == 0)
        #expect(counts[Self.hera] == 1)
    }

    @Test func aReseedOverwritesLiveCountsAndLeavesOtherHostsAlone() {
        let live = Self.seeded
            .receiving(.message(Self.message("zeus")), host: .local, isOnScreen: false)
            .seeding([LeoChatThread(agent: "zeus", unread: 9)], host: .remote("box"))
        let reseeded = live.seeding([LeoChatThread(agent: "zeus", unread: 2)], host: .local)
        #expect(reseeded[Self.zeus] == 2)
        #expect(reseeded[Self.hera] == 0)
        #expect(reseeded[Self.remoteZeus] == 9)
    }

    @Test(arguments: [(0, nil), (7, "7"), (99, "99"), (100, "99+")] as [(Int, String?)])
    func badgeTextHidesZeroAndCapsAtNinetyNine(count: Int, text: String?) {
        #expect(LeoChatUnreadCounts.badgeText(count) == text)
    }
}
