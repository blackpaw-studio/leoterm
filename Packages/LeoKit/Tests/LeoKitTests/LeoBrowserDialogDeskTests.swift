import Foundation
import Testing

@testable import LeoKit

/// B-412: a page's JavaScript dialogs wait on whoever answers first, the
/// user in the pane or the agent with `browser_dialog`, and the page hears
/// back exactly once.
@MainActor
struct LeoBrowserDialogDeskTests {
    private static let site = LeoBrowserSite(scheme: "https", host: "shop.example.com", port: nil)

    /// What the page heard back, in order.
    @MainActor private final class Replies {
        var list: [LeoBrowserDialogReply] = []
        func resolver() -> LeoBrowserDialogDesk.Resolver { { self.list.append($0) } }
    }

    private func open(
        _ desk: LeoBrowserDialogDesk, _ kind: LeoBrowserDialogKind, tab: Int = 1, message: String = "Delete it?",
        defaultText: String? = nil, replies: Replies
    ) throws -> LeoBrowserDialog {
        try #require(desk.open(tab: tab, kind: kind, message: message, defaultText: defaultText, site: Self.site, resolve: replies.resolver()))
    }

    @Test func firstAnswerWinsAndTheSecondSeesItWasHandled() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let dialog = try open(desk, .confirm, replies: replies)

        let first = desk.answer(inTab: 1, dialog: dialog.id, accept: true, by: .user)
        let second = desk.answer(inTab: 1, accept: false, by: .agent)

        let answer = LeoBrowserDialogAnswer(dialog: dialog, answerer: .user, accepted: true)
        #expect(first == .answered(answer))
        #expect(second == .alreadyHandled(answer))
        #expect(replies.list == [LeoBrowserDialogReply(accepted: true, text: nil)])
        #expect(desk.dialog(inTab: 1) == nil)
    }

    @Test func theUsersAnswerToAnOlderDialogNeverAnswersTheNextOne() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let older = try open(desk, .confirm, replies: replies)
        #expect(desk.answer(inTab: 1, accept: true, by: .agent) == .answered(.init(dialog: older, answerer: .agent, accepted: true)))
        let newer = try open(desk, .confirm, message: "Really?", replies: replies)

        // The user clicked the bar that still showed the older one.
        #expect(desk.answer(inTab: 1, dialog: older.id, accept: false, by: .user) == .alreadyHandled(.init(dialog: older, answerer: .agent, accepted: true)))
        #expect(desk.dialog(inTab: 1) == newer)
        #expect(replies.list.count == 1)
    }

    @Test func withdrawDismissesExactlyOnce() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        _ = try open(desk, .prompt, defaultText: "x", replies: replies)

        #expect(desk.withdraw(inTab: 1))
        #expect(!desk.withdraw(inTab: 1))
        #expect(desk.answer(inTab: 1, accept: true, by: .agent) == .noDialog)
        #expect(replies.list == [LeoBrowserDialogReply(accepted: false, text: nil)])
    }

    @Test func withdrawAllDismissesEveryTab() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        _ = try open(desk, .alert, tab: 1, replies: replies)
        _ = try open(desk, .leave, tab: 2, replies: replies)

        desk.withdrawAll()

        #expect(desk.dialogs.isEmpty)
        #expect(replies.list == [LeoBrowserDialogReply(accepted: true, text: nil), LeoBrowserDialogReply(accepted: false, text: nil)])
    }

    @Test func promptAcceptUsesTextElseDefaultAndDismissIsNil() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        _ = try open(desk, .prompt, defaultText: "Untitled", replies: replies)
        _ = desk.answer(inTab: 1, accept: true, text: "Report", by: .agent)
        _ = try open(desk, .prompt, defaultText: "Untitled", replies: replies)
        _ = desk.answer(inTab: 1, accept: true, by: .agent)
        _ = try open(desk, .prompt, replies: replies)
        _ = desk.answer(inTab: 1, accept: true, by: .user)
        _ = try open(desk, .prompt, defaultText: "Untitled", replies: replies)
        _ = desk.answer(inTab: 1, accept: false, text: "ignored", by: .user)

        #expect(replies.list.map(\.text) == ["Report", "Untitled", "", nil])
        #expect(replies.list.map(\.accepted) == [true, true, true, false])
    }

    @Test func anAlertHasOnlyOKSoDismissingItPressesOK() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let dialog = try open(desk, .alert, replies: replies)

        #expect(desk.answer(inTab: 1, accept: false, by: .agent) == .answered(.init(dialog: dialog, answerer: .agent, accepted: true)))
        #expect(replies.list == [LeoBrowserDialogReply(accepted: true, text: nil)])
    }

    @Test func acceptingALeaveDialogLeaves() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        _ = try open(desk, .leave, replies: replies)
        _ = desk.answer(inTab: 1, accept: true, by: .user)
        _ = try open(desk, .leave, replies: replies)
        _ = desk.answer(inTab: 1, accept: false, by: .agent)

        #expect(replies.list.map(\.accepted) == [true, false])
    }

    @Test func aSecondDialogInATabWithOneOpenIsDismissedAtOnce() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let first = try open(desk, .confirm, replies: replies)

        #expect(desk.open(tab: 1, kind: .confirm, message: "again", defaultText: nil, site: Self.site, resolve: replies.resolver()) == nil)
        #expect(replies.list == [LeoBrowserDialogReply(accepted: false, text: nil)])
        #expect(desk.dialog(inTab: 1) == first)
    }

    @Test func userAnswerLeavesANoteOnlyIfTheAgentWasTold() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let unseen = try open(desk, .confirm, tab: 1, replies: replies)
        _ = desk.answer(inTab: 1, dialog: unseen.id, accept: true, by: .user)
        #expect(desk.takeNotes().isEmpty)

        let seen = try open(desk, .confirm, tab: 2, replies: replies)
        desk.markTold(seen.id)
        _ = desk.answer(inTab: 2, dialog: seen.id, accept: false, by: .user)
        #expect(desk.takeNotes() == [LeoBrowserDialogAnswer(dialog: seen, answerer: .user, accepted: false)])
        #expect(desk.takeNotes().isEmpty)
    }

    @Test func theAgentsOwnAnswerOrAWithdrawLeavesNoNote() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let answered = try open(desk, .confirm, tab: 1, replies: replies)
        desk.markTold(answered.id)
        _ = desk.answer(inTab: 1, accept: true, by: .agent)
        let withdrawn = try open(desk, .confirm, tab: 2, replies: replies)
        desk.markTold(withdrawn.id)
        desk.withdraw(inTab: 2)

        #expect(desk.takeNotes().isEmpty)
    }

    @Test func reportingAHandledDialogToTheAgentUsesUpItsNote() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        let dialog = try open(desk, .confirm, replies: replies)
        desk.markTold(dialog.id)
        _ = desk.answer(inTab: 1, dialog: dialog.id, accept: true, by: .user)

        #expect(desk.answer(inTab: 1, accept: true, by: .agent) == .alreadyHandled(.init(dialog: dialog, answerer: .user, accepted: true)))
        #expect(desk.takeNotes().isEmpty)
    }

    @Test func aWithdrawnTabHasNoHandledDialogToReport() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        _ = try open(desk, .confirm, replies: replies)
        _ = desk.answer(inTab: 1, accept: true, by: .user)
        _ = try open(desk, .confirm, replies: replies)
        desk.withdraw(inTab: 1)

        #expect(desk.answer(inTab: 1, accept: true, by: .agent) == .noDialog)
    }

    @Test func observersHearOpensAnswersAndWithdrawalsUntilTheyStop() throws {
        let desk = LeoBrowserDialogDesk()
        let replies = Replies()
        var events: [LeoBrowserDialogDesk.Event] = []
        let stop = desk.observe { events.append($0) }
        let first = try open(desk, .confirm, tab: 1, replies: replies)
        _ = desk.answer(inTab: 1, accept: true, by: .agent)
        let second = try open(desk, .alert, tab: 2, replies: replies)
        desk.withdraw(inTab: 2)
        stop()
        _ = try open(desk, .alert, tab: 3, replies: replies)

        #expect(events == [
            .opened(first), .answered(.init(dialog: first, answerer: .agent, accepted: true)), .opened(second), .withdrawn(second),
        ])
    }

    // MARK: - Text

    @Test func agentMessageIsCappedAt1000Characters() {
        let long = String(repeating: "a", count: 1500)
        let quoted = LeoBrowserDialogText.quoted(long)
        #expect(quoted == "\"" + String(repeating: "a", count: 1000) + "…\"")
        #expect(LeoBrowserDialogText.quoted(String(repeating: "b", count: 1000)) == "\"" + String(repeating: "b", count: 1000) + "\"")
    }

    @Test func agentMessageIsQuotedOnOneLine() {
        #expect(LeoBrowserDialogText.quoted("Say \"hi\"\nthen go") == #""Say \"hi\"\nthen go""#)
    }

    @Test func buttonTitlesFollowTheKind() {
        #expect(LeoBrowserDialogText.buttonTitle(.alert, accepted: true) == "OK")
        #expect(LeoBrowserDialogText.buttonTitle(.confirm, accepted: false) == "Cancel")
        #expect(LeoBrowserDialogText.buttonTitle(.prompt, accepted: true) == "OK")
        #expect(LeoBrowserDialogText.buttonTitle(.leave, accepted: true) == "Leave Page")
        #expect(LeoBrowserDialogText.buttonTitle(.leave, accepted: false) == "Stay on Page")
    }

    @Test func theHandledNoteNamesWhoAnsweredAndHowButNeverTheTypedText() throws {
        let dialog = LeoBrowserDialog(id: 1, tab: 3, kind: .prompt, message: "Your name?", defaultText: "", site: Self.site)
        let note = LeoBrowserDialogText.handledNote(LeoBrowserDialogAnswer(dialog: dialog, answerer: .user, accepted: true))
        #expect(note == #"The user answered the JavaScript prompt in tab 3 ("Your name?") with OK, in the browser pane."#)
    }
}
