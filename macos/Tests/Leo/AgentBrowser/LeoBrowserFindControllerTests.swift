import AppKit
import Testing

@testable import Ghostty

/// A finder with a scripted answer per query. `gate(_:)` holds one query's
/// answer until `release(_:)`, to order replies against each other.
@MainActor final class FakePageFinder: LeoPageFinding {
    /// "search:<query>", "next:<query>", "previous:<query>", "clear".
    private(set) var calls: [String] = []
    /// The view each call named, in order.
    private(set) var views: [NSView?] = []
    var results: [String: LeoFindResult] = [:]
    var selection: String?
    private var gates: [String: CheckedContinuation<Void, Never>?] = [:]

    func gate(_ query: String) { gates[query] = .some(nil) }

    func release(_ query: String) {
        if let waiting = gates.removeValue(forKey: query), let waiting { waiting.resume() }
    }

    func search(_ query: String, in view: NSView?) async -> LeoFindResult {
        await answer("search:\(query)", query, view)
    }

    func step(_ direction: LeoFindDirection, query: String, in view: NSView?) async -> LeoFindResult {
        await answer("\(direction.rawValue):\(query)", query, view)
    }

    func clear(in view: NSView?) async {
        calls.append("clear")
        views.append(view)
    }

    func selectedText(in view: NSView?) async -> String? { selection }

    private func answer(_ call: String, _ query: String, _ view: NSView?) async -> LeoFindResult {
        calls.append(call)
        views.append(view)
        if gates[query] != nil {
            await withCheckedContinuation { gates[query] = .some($0) }
        }
        return results[query] ?? .none
    }
}

@MainActor
struct LeoBrowserFindControllerTests {
    private let finder = FakePageFinder()
    private let controller: LeoBrowserFindController
    private let page = NSView()

    init() {
        controller = LeoBrowserFindController(finder: finder)
        controller.pageChanged(to: page, isLoading: false)
        finder.results = [
            "ap": LeoFindResult(index: 1, total: 12, isCapped: false),
            "app": LeoFindResult(index: 1, total: 4, isCapped: false),
        ]
    }

    @Test func typingSearchesIncrementally() async {
        controller.show()
        controller.setQuery("ap")
        await controller.settled()
        #expect(controller.labelText == "1 of 12")

        controller.setQuery("app")
        await controller.settled()

        #expect(finder.calls.suffix(2) == ["search:ap", "search:app"])
        #expect(controller.labelText == "1 of 4")
    }

    @Test func staleResultIsDropped() async {
        finder.gate("ap")
        controller.show()
        controller.setQuery("ap")
        controller.setQuery("app")
        while !finder.calls.contains("search:app") { await Task.yield() }
        #expect(controller.result == finder.results["app"])

        finder.release("ap")
        await controller.settled()

        #expect(controller.result == finder.results["app"])
    }

    @Test func stepWithABarSteps() async {
        controller.show()
        controller.setQuery("ap")
        finder.results["ap"] = LeoFindResult(index: 2, total: 12, isCapped: false)

        controller.step(.next)
        await controller.settled()

        #expect(finder.calls.last == "next:ap")
        #expect(controller.labelText == "2 of 12")
    }

    @Test func stepWithoutABarOnlyShowsIt() async {
        controller.step(.next)
        await controller.settled()

        #expect(controller.isShown)
        #expect(!finder.calls.contains { $0.hasPrefix("next") })
    }

    @Test func stepWithNoQueryDoesNothing() async {
        controller.show()

        controller.step(.previous)
        await controller.settled()

        #expect(finder.calls.allSatisfy { !$0.hasPrefix("previous") })
    }

    @Test func hideClearsMarksAndResult() async {
        controller.show()
        controller.setQuery("ap")
        await controller.settled()

        controller.hide()
        await controller.settled()

        #expect(!controller.isShown)
        #expect(controller.result == nil)
        #expect(controller.labelText == "")
        #expect(finder.calls.last == "clear")
        #expect(controller.query == "ap")
    }

    @Test func reopeningSearchesTheKeptQueryAgain() async {
        controller.show()
        controller.setQuery("ap")
        controller.hide()
        await controller.settled()

        controller.show()
        await controller.settled()

        #expect(controller.labelText == "1 of 12")
    }

    @Test func changingTheActivePageClearsTheOldOneAndSearchesTheNew() async {
        controller.show()
        controller.setQuery("ap")
        await controller.settled()
        let other = NSView()

        controller.pageChanged(to: other, isLoading: false)
        await controller.settled()

        #expect(finder.calls.suffix(2) == ["clear", "search:ap"])
        #expect(finder.views.suffix(2).map { $0 === page ? "old" : $0 === other ? "new" : "?" } == ["old", "new"])
    }

    @Test func aHiddenBarDoesNotSearchOnPageChange() async {
        let before = finder.calls.count

        controller.pageChanged(to: NSView(), isLoading: false)
        await controller.settled()

        #expect(finder.calls.dropFirst(before).allSatisfy { $0 == "clear" })
    }

    @Test func finishingALoadSearchesAgain() async {
        controller.show()
        controller.setQuery("ap")
        await controller.settled()
        controller.pageChanged(to: page, isLoading: true)
        let count = finder.calls.count

        controller.pageChanged(to: page, isLoading: false)
        await controller.settled()

        #expect(finder.calls.dropFirst(count) == ["search:ap"])
    }

    @Test func useSelectionBecomesTheQuery() async {
        finder.selection = "ap"

        await controller.useSelection()
        await controller.settled()

        #expect(controller.isShown)
        #expect(controller.query == "ap")
        #expect(controller.labelText == "1 of 12")
    }

    @Test func labelText() async {
        #expect(controller.labelText == "")
        controller.show()
        controller.setQuery("zz")
        await controller.settled()
        #expect(controller.labelText == "No matches")

        finder.results["zz"] = LeoFindResult(index: 1, total: 1_000, isCapped: true)
        controller.setQuery("zzz")
        finder.results["zzz"] = finder.results["zz"]
        await controller.settled()
        #expect(controller.labelText == "1 of 1000+")

        controller.setQuery("")
        await controller.settled()
        #expect(controller.labelText == "")
    }
}
