import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// What the inbox says and which keys it acts on.
struct LeoInboxPresentationTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test func theSummaryNamesWhatNeedsYouAndWhatFinishedSinceYouLooked() {
        #expect(LeoInboxPresentation.summary(.init(needYou: 3, unreadFinished: 3, finished: 5)) == "3 need you · 3 finished since you looked")
        #expect(LeoInboxPresentation.summary(.init(needYou: 1, unreadFinished: 0, finished: 2)) == "1 needs you")
        #expect(LeoInboxPresentation.summary(.init(needYou: 0, unreadFinished: 2, finished: 2)) == "2 finished since you looked")
        #expect(LeoInboxPresentation.summary(.init(needYou: 0, unreadFinished: 0, finished: 4)) == "You're all caught up")
    }

    @Test func ageReadsAsTheLargestWholeUnit() {
        #expect(LeoInboxPresentation.age(of: now.addingTimeInterval(-20), now: now) == "now")
        #expect(LeoInboxPresentation.age(of: now.addingTimeInterval(-240), now: now) == "4m")
        #expect(LeoInboxPresentation.age(of: now.addingTimeInterval(-7300), now: now) == "2h")
        #expect(LeoInboxPresentation.age(of: now.addingTimeInterval(-200_000), now: now) == "2d")
        #expect(LeoInboxPresentation.age(of: nil, now: now) == nil)
    }

    @Test func aPermissionHeadlineJoinsToolAndCommand() {
        let item = LeoInboxItem(
            id: LeoAgentID(host: .local, name: "a"), kind: .permission(tool: "Bash", detail: "nomad job run x"), isUnread: true,
            agent: "a", machine: "This Mac"
        )
        #expect(LeoInboxPresentation.headline(item) == "Bash · nomad job run x")
    }

    @Test func keysMapToInboxActions() {
        #expect(LeoInboxKeyAction.action(keyCode: 126, modifiers: []) == .moveUp)
        #expect(LeoInboxKeyAction.action(keyCode: 125, modifiers: []) == .moveDown)
        #expect(LeoInboxKeyAction.action(keyCode: 36, modifiers: []) == .submit)
        #expect(LeoInboxKeyAction.action(keyCode: 76, modifiers: []) == .submit)
        #expect(LeoInboxKeyAction.action(keyCode: 36, modifiers: .command) == .goToAgent)
        #expect(LeoInboxKeyAction.action(keyCode: 51, modifiers: []) == .clearItem)
    }

    @Test func otherModifiersAndKeysAreNotTheInboxs() {
        #expect(LeoInboxKeyAction.action(keyCode: 36, modifiers: .control) == nil, "⌃↩ stays the terminal's / system's")
        #expect(LeoInboxKeyAction.action(keyCode: 125, modifiers: .command) == nil)
        #expect(LeoInboxKeyAction.action(keyCode: 36, modifiers: [.command, .shift]) == nil)
        #expect(LeoInboxKeyAction.action(keyCode: 0, modifiers: []) == nil)
    }
}
