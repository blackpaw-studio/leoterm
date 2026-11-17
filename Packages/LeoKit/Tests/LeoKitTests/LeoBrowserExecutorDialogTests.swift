import Foundation
import Testing

@testable import LeoKit

/// B-412: what the agent sees of a page's JavaScript dialogs, and how
/// `browser_dialog` answers them. A dialog pauses its page, so tools that
/// need the page fail fast, and a call that opens one comes back at once.
@MainActor
struct LeoBrowserExecutorDialogTests {
    @MainActor private struct Harness {
        let executor: LeoBrowserExecutor
        let tabs: FakeTabs
        let control: LeoBrowserControlModel
        let replies: Replies

        var desk: LeoBrowserDialogDesk { tabs.dialogs }
        func page(_ id: Int) -> FakePage { tabs.pages[id]! }
    }

    @MainActor final class Replies {
        var list: [LeoBrowserDialogReply] = []
    }

    /// Port 49152 is the forward of the agent's 5173 (see FakeMapping).
    private static let site = LeoBrowserSite(scheme: "http", host: "localhost", port: 49152)

    private func harness(pageCount: Int = 2) -> Harness {
        let tabs = FakeTabs(pageCount: pageCount)
        let control = LeoBrowserControlModel()
        let executor = LeoBrowserExecutor(tabs: tabs, urlMapping: FakeMapping(), control: control, sleep: { _ in })
        return Harness(executor: executor, tabs: tabs, control: control, replies: Replies())
    }

    @discardableResult
    private func open(
        _ h: Harness, _ kind: LeoBrowserDialogKind, tab: Int = 1, message: String = "Delete report.pdf?", defaultText: String? = nil
    ) -> LeoBrowserDialog? {
        h.desk.open(tab: tab, kind: kind, message: message, defaultText: defaultText, site: Self.site) { h.replies.list.append($0) }
    }

    private func run(_ h: Harness, _ tool: String, _ args: [String: LeoJSONValue] = [:]) async -> LeoClientToolOutcome {
        await h.executor.execute(tool: tool, args: .object(args), requestID: "r")
    }

    private func texts(_ outcome: LeoClientToolOutcome) -> [String] {
        guard case .success(let content) = outcome else { return [] }
        return content.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    private func error(_ outcome: LeoClientToolOutcome) -> LeoClientToolError? {
        guard case .failure(let error) = outcome else { return nil }
        return error
    }

    private func tabList(_ outcome: LeoClientToolOutcome) throws -> [[String: Any]] {
        let text = try #require(texts(outcome).first)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    /// Spins the main actor until `condition` holds (bounded, no wall-clock sleep).
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }

    // MARK: - While a dialog is open

    @Test func pageToolsFailWithDialogOpenWhilePending() async throws {
        let h = harness()
        open(h, .confirm)

        let calls: [(String, [String: LeoJSONValue])] = [
            ("browser_snapshot", [:]), ("browser_click", ["ref": .string("e1")]), ("browser_navigate", ["url": .string("https://a.test")]),
            ("browser_screenshot", [:]), ("browser_eval", ["js": .string("1")]), ("browser_wait", ["text": .string("x")]),
        ]
        for (tool, args) in calls {
            let failure = try #require(error(await run(h, tool, args)), "\(tool)")
            #expect(failure.code == "dialog_open", "\(tool)")
            for phrase in ["Tab 1", "JavaScript confirm", #""Delete report.pdf?""#, "http://localhost:5173", "browser_dialog", "paused"] {
                #expect(failure.message.contains(phrase), "\(tool): \(phrase)")
            }
        }
        #expect(h.page(1).calls.isEmpty)
        // Another tab's page isn't paused.
        #expect(texts(await run(h, "browser_snapshot", ["tab": .int(2)])) == [""])
    }

    @Test func toolsThatDontNeedThePausedPageStillWork() async {
        let h = harness()
        open(h, .alert)

        for (tool, args) in [
            ("browser_tabs", [:]), ("browser_downloads", [:]), ("browser_console", [:]), ("browser_wait", ["ms": .int(5)]),
            ("browser_tab_select", ["tab": .int(2)]), ("browser_tab_new", [:]), ("browser_tab_close", ["tab": .int(3)]),
        ] as [(String, [String: LeoJSONValue])] {
            #expect(error(await run(h, tool, args)) == nil, "\(tool)")
        }
    }

    @Test func tabsRowShowsThePendingDialog() async throws {
        let h = harness()
        open(h, .prompt, tab: 2, message: String(repeating: "m", count: 1200), defaultText: "Untitled")

        let rows = try tabList(await run(h, "browser_tabs"))
        #expect(rows[0]["dialog"] == nil)
        let dialog = try #require(rows[1]["dialog"] as? [String: String])
        #expect(dialog["kind"] == "prompt")
        #expect(dialog["default_text"] == "Untitled")
        #expect(dialog["site"] == "http://localhost:5173")
        #expect(dialog["message"] == String(repeating: "m", count: 1000) + "…")
    }

    @Test func tabsRowNamesALeaveDialogWithTheBrowsersOwnQuestion() async throws {
        let h = harness()
        open(h, .leave, message: "page text")

        let dialog = try #require(try tabList(await run(h, "browser_tabs"))[0]["dialog"] as? [String: String])
        #expect(dialog == ["kind": "beforeunload", "message": LeoBrowserDialogText.leaveMessage, "site": "http://localhost:5173"])
    }

    // MARK: - A call that opens a dialog

    @Test func callThatOpensADialogReturnsAtOnceWithIt() async throws {
        let h = harness()
        let latch = Latch()
        h.page(1).clickGate = latch
        let click = Task { await run(h, "browser_click", ["ref": .string("e1")]) }
        await settle { h.page(1).calls == ["click e1"] }

        let dialog = try #require(open(h, .confirm))
        let outcome = await click.value

        let text = try #require(texts(outcome).first)
        #expect(text == LeoBrowserDialogText.openedLine(dialog, origin: "http://localhost:5173"))
        // The queue is free though the click never finished.
        #expect(error(await run(h, "browser_snapshot", ["tab": .int(2)])) == nil)
        latch.open()
        await settle { true }
    }

    @Test func dialogOnAnotherTabAlsoEndsTheStuckCall() async throws {
        let h = harness()
        let latch = Latch()
        h.page(1).clickGate = latch
        let click = Task { await run(h, "browser_click", ["ref": .string("e1")]) }
        await settle { h.page(1).calls == ["click e1"] }

        open(h, .alert, tab: 2, message: "Saved")

        #expect(texts(await click.value).first?.hasPrefix(#"While this call ran, tab 2 opened a JavaScript alert, from http://localhost:5173: "Saved"."#) == true)
        latch.open()
    }

    @Test func aDialogThatWasAlreadyOpenDoesNotEndAnotherTabsCall() async {
        let h = harness()
        open(h, .alert, tab: 2)
        let latch = Latch()
        h.page(1).clickGate = latch
        var outcome: LeoClientToolOutcome?
        let click = Task { outcome = await run(h, "browser_click", ["ref": .string("e1")]) }
        await settle { h.page(1).calls == ["click e1"] }
        for _ in 0..<20 { await Task.yield() }
        #expect(outcome == nil)

        latch.open()
        await click.value
        #expect(texts(outcome!) == ["ok"])
    }

    // MARK: - browser_dialog

    @Test func dialogToolAnswersWhileAnotherCallIsStuck() async {
        let h = harness()
        open(h, .confirm)
        let latch = Latch()
        h.page(2).snapshotGate = latch
        let stuck = Task { await run(h, "browser_snapshot", ["tab": .int(2)]) }
        await settle { h.page(2).calls == ["snapshot"] }

        #expect(texts(await run(h, "browser_dialog", ["action": .string("accept")])) == ["ok"])
        #expect(h.replies.list == [LeoBrowserDialogReply(accepted: true, text: nil)])
        latch.open()
        _ = await stuck.value
    }

    @Test func dialogToolAcceptsWithPromptTextAndDismisses() async {
        let h = harness()
        open(h, .prompt, tab: 2, defaultText: "Untitled")
        #expect(texts(await run(h, "browser_dialog", ["action": .string("accept"), "text": .string("Q3"), "tab": .int(2)])) == ["ok"])
        open(h, .confirm)
        #expect(texts(await run(h, "browser_dialog", ["action": .string("dismiss")])) == ["ok"])
        open(h, .leave)
        #expect(texts(await run(h, "browser_dialog", ["action": .string("accept")])) == ["ok"])

        #expect(h.replies.list == [
            LeoBrowserDialogReply(accepted: true, text: "Q3"), LeoBrowserDialogReply(accepted: false, text: nil),
            LeoBrowserDialogReply(accepted: true, text: nil),
        ])
    }

    @Test func textWithAcceptOnAConfirmIsInvalidArgsAndLeavesItOpen() async {
        let h = harness()
        open(h, .confirm)

        let failure = error(await run(h, "browser_dialog", ["action": .string("accept"), "text": .string("yes")]))
        #expect(failure?.code == "invalid_args")
        #expect(failure?.message.contains("confirm") == true)
        #expect(h.desk.dialog(inTab: 1) != nil)
        #expect(h.replies.list.isEmpty)
    }

    @Test func dialogToolFailsWithNoDialog() async {
        let h = harness()
        open(h, .confirm, tab: 2)

        let failure = error(await run(h, "browser_dialog", ["action": .string("accept")]))
        #expect(failure?.code == "no_dialog")
        #expect(failure?.message == "No JavaScript dialog is open in tab 1; tab 2 has a JavaScript confirm open (pass tab: 2).")
        #expect(error(await run(h, "browser_dialog", ["action": .string("accept"), "tab": .int(9)]))?.code == "no_such_tab")
    }

    @Test func dialogToolFailsWithDialogHandledNamingTheUsersAnswer() async throws {
        let h = harness()
        let dialog = try #require(open(h, .confirm))
        _ = await run(h, "browser_tabs")
        _ = h.desk.answer(inTab: 1, dialog: dialog.id, accept: false, by: .user)

        let outcome = await run(h, "browser_dialog", ["action": .string("accept")])

        #expect(error(outcome)?.code == "dialog_handled")
        #expect(error(outcome)?.message.hasPrefix(#"The user already answered the JavaScript confirm in tab 1 ("Delete report.pdf?") with Cancel"#) == true)
        #expect(h.replies.list == [LeoBrowserDialogReply(accepted: false, text: nil)])
        // It was said once, as the error, not again as a note.
        #expect(texts(await run(h, "browser_tabs")).count == 1)
    }

    @Test func nextResultCarriesTheHandledNoteOnce() async throws {
        let h = harness()
        let dialog = try #require(open(h, .confirm))
        #expect(error(await run(h, "browser_snapshot"))?.code == "dialog_open")
        _ = h.desk.answer(inTab: 1, dialog: dialog.id, accept: true, by: .user)

        let first = texts(await run(h, "browser_tabs"))
        let second = texts(await run(h, "browser_tabs"))

        #expect(first.count == 2)
        #expect(first.last == LeoBrowserDialogText.handledNote(.init(dialog: dialog, answerer: .user, accepted: true)))
        #expect(second.count == 1)
    }

    @Test func aFailedCallCarriesTheNoteInItsMessage() async throws {
        let h = harness()
        let dialog = try #require(open(h, .confirm))
        _ = await run(h, "browser_tabs")
        _ = h.desk.answer(inTab: 1, dialog: dialog.id, accept: true, by: .user)

        let failure = error(await run(h, "browser_click", ["ref": .string("e1"), "tab": .int(7)]))

        #expect(failure?.code == "no_such_tab")
        #expect(failure?.message.hasSuffix(LeoBrowserDialogText.handledNote(.init(dialog: dialog, answerer: .user, accepted: true))) == true)
    }

    @Test func dialogToolFailsWithUserHasControl() async {
        let h = harness()
        open(h, .confirm)
        h.control.send(.userInput)

        #expect(error(await run(h, "browser_dialog", ["action": .string("accept")]))?.code == "user_has_control")
        #expect(h.replies.list.isEmpty)
    }

    @Test func tabCloseWorksWhilePendingAndDismisses() async {
        let h = harness()
        open(h, .confirm)

        #expect(texts(await run(h, "browser_tab_close", ["tab": .int(1)])) == ["ok"])
        #expect(h.replies.list == [LeoBrowserDialogReply(accepted: false, text: nil)])
    }
}
