import Foundation
import Testing

@testable import LeoKit

@MainActor
struct LeoBrowserExecutorTests {
    // MARK: - Harness

    @MainActor private struct Harness {
        let executor: LeoBrowserExecutor
        let tabs: FakeTabs
        let control: LeoBrowserControlModel
        let mapping: FakeMapping
        let sleeps: SleepLog

        var page: FakePage { tabs.pages[tabs.activeID!]! }
    }

    private func harness(pageCount: Int = 1) -> Harness {
        let tabs = FakeTabs(pageCount: pageCount)
        let control = LeoBrowserControlModel()
        let mapping = FakeMapping()
        let sleeps = SleepLog()
        let executor = LeoBrowserExecutor(tabs: tabs, urlMapping: mapping, control: control, sleep: { sleeps.durations.append($0) })
        return Harness(executor: executor, tabs: tabs, control: control, mapping: mapping, sleeps: sleeps)
    }

    private func run(_ harness: Harness, _ tool: String, _ args: [String: LeoJSONValue] = [:], id: String = "r1") async -> LeoClientToolOutcome {
        await harness.executor.execute(tool: tool, args: .object(args), requestID: id)
    }

    private func texts(_ outcome: LeoClientToolOutcome) -> [String] {
        guard case .success(let content) = outcome else { return [] }
        return content.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    private func json(_ outcome: LeoClientToolOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> [String: Any] {
        guard let text = texts(outcome).first, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            Issue.record("expected a JSON object result, got \(outcome)", sourceLocation: sourceLocation)
            return [:]
        }
        return object
    }

    private func errorCode(_ outcome: LeoClientToolOutcome) -> String? {
        guard case .failure(let error) = outcome else { return nil }
        return error.code
    }

    // MARK: - Command mapping and result shapes

    @Test func navigateLoadsTheMappedURLAndReportsRemoteTerms() async {
        let h = harness()
        h.page.currentURL = URL(string: "http://localhost:49152/app")
        h.page.currentTitle = "App"

        let outcome = await run(h, "browser_navigate", ["url": .string("http://localhost:5173/app")])

        #expect(h.page.calls == ["load http://localhost:49152/app"])
        #expect(json(outcome)["url"] as? String == "http://localhost:5173/app")
        #expect(json(outcome)["title"] as? String == "App")
    }

    @Test func navigateRefusesDisallowedSchemesWithoutTouchingThePage() async {
        let h = harness()
        let outcome = await run(h, "browser_navigate", ["url": .string("file:///etc/passwd")])
        #expect(errorCode(outcome) == "scheme_not_allowed")
        #expect(h.page.calls.isEmpty)
        #expect(h.mapping.localCalls.isEmpty)
    }

    @Test func aFailedForwardBecomesNavigationFailed() async {
        let h = harness()
        h.mapping.localError = LeoBrowserError(.navigationFailed, "Port forward failed")
        let outcome = await run(h, "browser_navigate", ["url": .string("http://localhost:5173/")])
        #expect(errorCode(outcome) == "navigation_failed")
        #expect(h.page.calls.isEmpty)
    }

    @Test(arguments: [("browser_back", "goBack"), ("browser_forward", "goForward"), ("browser_reload", "reload")])
    func historyToolsCallThePageAndReportUrlAndTitle(tool: String, call: String) async {
        let h = harness()
        h.page.currentURL = URL(string: "http://localhost:49152/x")
        h.page.currentTitle = "X"
        let outcome = await run(h, tool)
        #expect(h.page.calls == [call])
        #expect(json(outcome)["url"] as? String == "http://localhost:5173/x")
        #expect(json(outcome)["title"] as? String == "X")
    }

    @Test func snapshotReturnsThePageTextVerbatim() async {
        let h = harness()
        h.page.snapshotText = "button \"Go\" [e1]"
        #expect(texts(await run(h, "browser_snapshot")) == ["button \"Go\" [e1]"])
    }

    @Test func clickTypePressMapToPageCalls() async {
        let h = harness()
        #expect(texts(await run(h, "browser_click", ["ref": .string("e1")])) == ["ok"])
        #expect(texts(await run(h, "browser_type", ["ref": .string("e2"), "text": .string("hi"), "submit": .bool(true)])) == ["ok"])
        #expect(texts(await run(h, "browser_press", ["key": .string("Meta+a")])) == ["ok"])
        #expect(h.page.calls == ["click e1", "type e2 hi submit=true", "press meta+a"])
    }

    @Test func screenshotReturnsAPNGImageBlock() async throws {
        let h = harness()
        h.page.screenshotData = Data([0x89, 0x50, 0x4E, 0x47])
        guard case .success(let content) = await run(h, "browser_screenshot", ["full_page": .bool(true)]) else { Issue.record("expected success"); return }
        #expect(content == [.image(data: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(), mimeType: "image/png")])
        #expect(h.page.calls == ["screenshot full=true"])
    }

    @Test func evalReturnsTheSerialisedResult() async {
        let h = harness()
        h.page.evalResult = "{\"a\":1}"
        #expect(texts(await run(h, "browser_eval", ["js": .string("({a:1})")])) == ["{\"a\":1}"])
        #expect(h.page.calls == ["eval ({a:1})"])
    }

    @Test func consoleReturnsMessagesAndTheNextCursor() async {
        let h = harness()
        h.page.console = LeoBrowserConsoleBatch(entries: [.init(level: "error", text: "boom")], cursor: 5)
        let object = json(await run(h, "browser_console", ["since": .int(3)]))
        #expect(object["cursor"] as? Int == 5)
        let messages = object["messages"] as? [[String: String]]
        #expect(messages == [["level": "error", "text": "boom"]])
        #expect(h.page.calls == ["console since=3"])
    }

    @Test func waitForTextUsesThePageWithTheMaximumTimeout() async {
        let h = harness()
        #expect(texts(await run(h, "browser_wait", ["text": .string("Done")])) == ["ok"])
        #expect(h.page.calls == ["waitForText Done 25000"])
    }

    @Test func waitForTimeUsesTheInjectedSleeperNotThePage() async {
        let h = harness()
        #expect(texts(await run(h, "browser_wait", ["ms": .int(250)])) == ["ok"])
        #expect(h.sleeps.durations == [.milliseconds(250)])
        #expect(h.page.calls.isEmpty)
    }

    @Test func invalidArgsAreReportedNotThrown() async {
        let h = harness()
        #expect(errorCode(await run(h, "browser_click")) == "invalid_args")
        #expect(errorCode(await run(h, "browser_wait", ["ms": .int(99_999)])) == "invalid_args")
        #expect(errorCode(await run(h, "browser_nope")) == "invalid_args")
        #expect(h.page.calls.isEmpty)
    }

    // MARK: - Errors from the page

    @Test func browserErrorsFromThePagePassThroughWithTheirCode() async {
        let h = harness()
        h.page.error = LeoBrowserError.staleRef("e9")
        let outcome = await run(h, "browser_click", ["ref": .string("e9")])
        guard case .failure(let error) = outcome else { Issue.record("expected failure"); return }
        #expect(error.code == "stale_ref")
        #expect(error.message.contains("e9"))
    }

    @Test func unexpectedPageErrorsFallBackToAnActionAppropriateCode() async {
        struct Boom: Error {}
        let h = harness()
        h.page.error = Boom()
        #expect(errorCode(await run(h, "browser_navigate", ["url": .string("https://a.test/")])) == "navigation_failed")
        #expect(errorCode(await run(h, "browser_eval", ["js": .string("1")])) == "js_error")
        #expect(errorCode(await run(h, "browser_click", ["ref": .string("e1")])) == "js_error")
    }

    // MARK: - Tabs

    @Test func pageToolsTargetTheGivenTabOrTheActiveOne() async {
        let h = harness(pageCount: 2)
        h.tabs.activeID = 1
        _ = await run(h, "browser_click", ["ref": .string("e1"), "tab": .int(2)])
        _ = await run(h, "browser_click", ["ref": .string("e2")])
        #expect(h.tabs.pages[2]!.calls == ["click e1"])
        #expect(h.tabs.pages[1]!.calls == ["click e2"])
    }

    @Test func anUnknownTabOrNoTabsIsNoSuchTab() async {
        let h = harness()
        #expect(errorCode(await run(h, "browser_snapshot", ["tab": .int(99)])) == "no_such_tab")
        #expect(errorCode(await run(h, "browser_tab_select", ["tab": .int(99)])) == "no_such_tab")
        #expect(errorCode(await run(h, "browser_tab_close", ["tab": .int(99)])) == "no_such_tab")
        let empty = harness(pageCount: 0)
        #expect(errorCode(await run(empty, "browser_snapshot")) == "no_such_tab")
    }

    @Test func navigateWithNoTabsOpensOneAtTheMappedURL() async {
        let h = harness(pageCount: 0)
        let outcome = await run(h, "browser_navigate", ["url": .string("http://localhost:5173/app")])
        #expect(h.tabs.opened == ["http://localhost:49152/app"])
        #expect(h.tabs.tabs.count == 1)
        #expect(json(outcome)["url"] != nil)
    }

    @Test func navigateWithNoTabsStillValidatesTheURLAndHonorsAnExplicitTab() async {
        let h = harness(pageCount: 0)
        #expect(errorCode(await run(h, "browser_navigate", ["url": .string("file:///etc/passwd")])) == "scheme_not_allowed")
        #expect(errorCode(await run(h, "browser_navigate", ["url": .string("http://localhost:5173/"), "tab": .int(7)])) == "no_such_tab")
        #expect(h.tabs.opened.isEmpty)
    }

    @Test func tabsListsIdUrlTitleAndActiveInRemoteTerms() async {
        let h = harness(pageCount: 2)
        h.tabs.pages[2]!.currentURL = URL(string: "http://localhost:49152/two")
        h.tabs.pages[2]!.currentTitle = "Two"
        h.tabs.activeID = 2
        guard case .success(let content) = await run(h, "browser_tabs"), case .text(let text) = content.first,
              let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { Issue.record("expected a JSON list"); return }
        #expect(list.map { $0["id"] as? Int } == [1, 2])
        #expect(list.map { $0["active"] as? Bool } == [false, true])
        #expect(list[1]["url"] as? String == "http://localhost:5173/two")
        #expect(list[1]["title"] as? String == "Two")
    }

    @Test func tabNewOpensWithTheMappedURLAndReturnsTheNewID() async {
        let h = harness()
        let outcome = await run(h, "browser_tab_new", ["url": .string("http://localhost:5173/")])
        #expect(json(outcome)["tab"] as? Int == 2)
        #expect(h.tabs.opened == ["http://localhost:49152/"])
        #expect(h.tabs.activeID == 2)
    }

    @Test func tabNewWithoutAURLOpensABlankTab() async {
        let h = harness()
        _ = await run(h, "browser_tab_new")
        #expect(h.tabs.opened == ["about:blank"])
    }

    @Test func theEleventhTabIsTabLimitAndOpensNothing() async {
        let h = harness(pageCount: LeoBrowserLimits.maximumTabs)
        #expect(errorCode(await run(h, "browser_tab_new")) == "tab_limit")
        #expect(h.tabs.opened.isEmpty)
        let nine = harness(pageCount: LeoBrowserLimits.maximumTabs - 1)
        #expect(errorCode(await run(nine, "browser_tab_new")) == nil)
    }

    @Test func tabNewRefusesDisallowedSchemes() async {
        let h = harness()
        #expect(errorCode(await run(h, "browser_tab_new", ["url": .string("javascript:alert(1)")])) == "scheme_not_allowed")
        #expect(h.tabs.opened.isEmpty)
    }

    @Test func selectAndCloseActOnTheNamedTab() async {
        let h = harness(pageCount: 2)
        #expect(texts(await run(h, "browser_tab_select", ["tab": .int(2)])) == ["ok"])
        #expect(h.tabs.activeID == 2)
        #expect(texts(await run(h, "browser_tab_close", ["tab": .int(1)])) == ["ok"])
        #expect(h.tabs.pages.keys.sorted() == [2])
    }

    // MARK: - User control

    @Test func whileTheUserHasControlEveryPageChangingToolFailsAndNothingRuns() async {
        let h = harness()
        h.control.send(.userInput)
        let calls: [(String, [String: LeoJSONValue])] = [
            ("browser_navigate", ["url": .string("https://a.test/")]), ("browser_back", [:]), ("browser_forward", [:]),
            ("browser_reload", [:]), ("browser_click", ["ref": .string("e1")]),
            ("browser_type", ["ref": .string("e1"), "text": .string("x")]), ("browser_press", ["key": .string("Enter")]),
            ("browser_eval", ["js": .string("1")]), ("browser_tab_new", [:]), ("browser_tab_select", ["tab": .int(1)]),
            ("browser_tab_close", ["tab": .int(1)]),
        ]
        for (tool, args) in calls {
            let outcome = await run(h, tool, args)
            #expect(errorCode(outcome) == "user_has_control", "\(tool)")
        }
        #expect(h.page.calls.isEmpty)
        #expect(h.tabs.opened.isEmpty)
        #expect(h.mapping.localCalls.isEmpty)
    }

    @Test func readsStillWorkWhileTheUserHasControl() async {
        let h = harness()
        h.control.send(.userInput)
        h.page.snapshotText = "page"
        #expect(texts(await run(h, "browser_snapshot")) == ["page"])
        #expect(errorCode(await run(h, "browser_screenshot")) == nil)
        #expect(errorCode(await run(h, "browser_tabs")) == nil)
        #expect(errorCode(await run(h, "browser_console")) == nil)
        #expect(errorCode(await run(h, "browser_wait", ["text": .string("x")])) == nil)
    }

    @Test func theUserErrorMessagePointsAtHandoff() async {
        let h = harness()
        h.control.send(.userInput)
        guard case .failure(let error) = await run(h, "browser_click", ["ref": .string("e1")]) else { Issue.record("expected failure"); return }
        #expect(error.message.contains("browser_handoff"))
    }

    // MARK: - Handoff

    @Test func handoffBlocksUntilDoneThenReturnsDoneAndGivesControlBack() async {
        let h = harness()
        let task = Task { await run(h, "browser_handoff", ["message": .string("Log in")], id: "h1") }
        await settle { h.control.state.pendingHandoff != nil }
        #expect(h.control.state == .handoff(requestID: "h1", message: "Log in"))

        h.control.send(.done(requestID: "h1"))

        #expect(texts(await task.value) == ["done"])
        #expect(h.control.state == .agent)
    }

    @Test func handoffDeclineReturnsDeclined() async {
        let h = harness()
        let task = Task { await run(h, "browser_handoff", ["message": .string("Captcha")], id: "h1") }
        await settle { h.control.state.pendingHandoff != nil }
        h.control.send(.decline(requestID: "h1"))
        #expect(texts(await task.value) == ["declined"])
    }

    @Test func aPendingHandoffDoesNotBlockReadsButStillBlocksPageChanges() async {
        let h = harness()
        h.page.snapshotText = "page"
        let handoff = Task { await run(h, "browser_handoff", ["message": .string("Log in")], id: "h1") }
        await settle { h.control.state.pendingHandoff != nil }

        #expect(texts(await run(h, "browser_snapshot", id: "r2")) == ["page"])
        #expect(errorCode(await run(h, "browser_click", ["ref": .string("e1")], id: "r3")) == "user_has_control")

        h.control.send(.done(requestID: "h1"))
        _ = await handoff.value
    }

    @Test func cancellingAHandoffDismissesItAndLeavesTheUserInControl() async {
        let h = harness()
        let task = Task { await run(h, "browser_handoff", ["message": .string("Log in")], id: "h1") }
        await settle { h.control.state.pendingHandoff != nil }

        task.cancel()
        let outcome = await task.value

        #expect(errorCode(outcome) == "cancelled")
        #expect(h.control.state == .user)
    }

    // MARK: - Serialisation

    @Test func operationsRunOneAtATimeInArrivalOrder() async {
        let h = harness()
        let latch = Latch()
        h.page.snapshotGate = latch
        let first = Task { await run(h, "browser_snapshot", id: "a") }
        await settle { h.page.calls == ["snapshot"] }
        let second = Task { await run(h, "browser_click", ["ref": .string("e1")], id: "b") }
        let third = Task { await run(h, "browser_press", ["key": .string("Enter")], id: "c") }
        // The first op is suspended inside the page; the others must not have started.
        for _ in 0..<20 { await Task.yield() }
        #expect(h.page.calls == ["snapshot"])

        latch.open()
        _ = await (first.value, second.value, third.value)
        #expect(h.page.calls == ["snapshot", "click e1", "press enter"])
    }

    @Test func aCancelledQueuedOperationNeverRuns() async {
        let h = harness()
        let latch = Latch()
        h.page.snapshotGate = latch
        let first = Task { await run(h, "browser_snapshot", id: "a") }
        await settle { h.page.calls == ["snapshot"] }
        let queued = Task { await run(h, "browser_click", ["ref": .string("e1")], id: "b") }
        for _ in 0..<5 { await Task.yield() }

        queued.cancel()
        #expect(errorCode(await queued.value) == "cancelled")
        latch.open()
        _ = await first.value
        #expect(h.page.calls == ["snapshot"])
    }

    @Test func aQueuedPageChangeFailsIfTheUserTakesControlBeforeItsTurn() async {
        let h = harness()
        let latch = Latch()
        h.page.snapshotGate = latch
        let snapshot = Task { await run(h, "browser_snapshot", id: "a") }
        await settle { h.page.calls == ["snapshot"] }
        let click = Task { await run(h, "browser_click", ["ref": .string("e1")], id: "b") }
        for _ in 0..<20 { await Task.yield() }

        h.control.send(.userInput)
        latch.open()

        #expect(errorCode(await click.value) == "user_has_control")
        _ = await snapshot.value
        #expect(h.page.calls == ["snapshot"])
    }

    @Test func aHandoffIsNotQueuedBehindARunningOperation() async {
        let h = harness()
        let latch = Latch()
        h.page.snapshotGate = latch
        let snapshot = Task { await run(h, "browser_snapshot", id: "a") }
        await settle { h.page.calls == ["snapshot"] }

        let handoff = Task { await run(h, "browser_handoff", ["message": .string("hi")], id: "h1") }
        await settle { h.control.state.pendingHandoff != nil }

        h.control.send(.done(requestID: "h1"))
        #expect(texts(await handoff.value) == ["done"])
        latch.open()
        _ = await snapshot.value
    }

    /// Spins the main actor until `condition` holds (bounded, no wall-clock sleep).
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }
}

// MARK: - Fakes

@MainActor
final class Latch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SleepLog {
    var durations: [Duration] = []
}

@MainActor
private final class FakePage: LeoBrowserPage {
    var calls: [String] = []
    var currentURL: URL? = URL(string: "about:blank")
    var currentTitle = ""
    var snapshotText = ""
    var screenshotData = Data()
    var evalResult = "null"
    var console = LeoBrowserConsoleBatch(entries: [], cursor: 0)
    var error: (any Error)?
    var snapshotGate: Latch?

    var url: URL? { currentURL }
    var title: String { currentTitle }

    private func record(_ call: String) throws {
        calls.append(call)
        if let error { throw error }
    }

    func load(_ url: URL) async throws { try record("load \(url.absoluteString)") }
    func goBack() async throws { try record("goBack") }
    func goForward() async throws { try record("goForward") }
    func reload() async throws { try record("reload") }

    func snapshot() async throws -> String {
        try record("snapshot")
        await snapshotGate?.wait()
        return snapshotText
    }

    func click(ref: String) async throws { try record("click \(ref)") }
    func type(ref: String, text: String, submit: Bool) async throws { try record("type \(ref) \(text) submit=\(submit)") }

    func press(_ combo: LeoBrowserKeyCombo) async throws {
        let names: [(LeoBrowserKeyCombo.Modifiers, String)] = [(.shift, "shift"), (.control, "control"), (.alt, "alt"), (.meta, "meta")]
        let prefix = names.filter { combo.modifiers.contains($0.0) }.map { "\($0.1)+" }.joined()
        try record("press \(prefix)\(combo.key.lowercased())")
    }

    func screenshot(fullPage: Bool) async throws -> Data {
        try record("screenshot full=\(fullPage)")
        return screenshotData
    }

    func waitForText(_ text: String, timeoutMilliseconds: Int) async throws { try record("waitForText \(text) \(timeoutMilliseconds)") }

    func evaluate(_ js: String) async throws -> String {
        try record("eval \(js)")
        return evalResult
    }

    func consoleMessages(since: Int?) -> LeoBrowserConsoleBatch {
        calls.append("console since=\(since.map(String.init) ?? "nil")")
        return console
    }
}

@MainActor
private final class FakeTabs: LeoBrowserTabs {
    var pages: [Int: FakePage] = [:]
    var activeID: Int?
    var opened: [String] = []
    private var nextID = 1

    init(pageCount: Int) {
        for _ in 0..<pageCount { _ = add() }
        activeID = pages.keys.sorted().first
    }

    private func add() -> Int {
        let id = nextID
        nextID += 1
        pages[id] = FakePage()
        return id
    }

    var tabs: [LeoBrowserTabInfo] {
        pages.keys.sorted().map { LeoBrowserTabInfo(id: $0, url: pages[$0]!.url, title: pages[$0]!.title, isActive: $0 == activeID) }
    }

    func page(forTab id: Int?) -> (any LeoBrowserPage)? { (id ?? activeID).flatMap { pages[$0] } }

    func openTab(url: URL) async throws -> Int {
        opened.append(url.absoluteString)
        let id = add()
        activeID = id
        return id
    }

    func selectTab(_ id: Int) { activeID = id }

    func closeTab(_ id: Int) {
        pages[id] = nil
        if activeID == id { activeID = pages.keys.sorted().first }
    }
}

/// Maps remote-terms `:5173` to a local `:49152`, like a port forward whose
/// same-numbered local port was taken.
@MainActor
private final class FakeMapping: LeoBrowserURLMapping {
    var localCalls: [String] = []
    var localError: LeoBrowserError?

    func toLocal(_ url: URL) async throws -> URL {
        localCalls.append(url.absoluteString)
        if let localError { throw localError }
        return Self.swapPort(url, from: 5173, to: 49152)
    }

    func toRemote(_ url: URL) -> URL { Self.swapPort(url, from: 49152, to: 5173) }

    private static func swapPort(_ url: URL, from: Int, to: Int) -> URL {
        guard url.port == from, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.port = to
        return parts.url ?? url
    }
}
