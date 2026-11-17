import AppKit

/// The find bar's state (B-407): the query, whether the bar is up and the
/// last result, kept in step with the active page. A search answered after a
/// newer one started, or after the page changed, is dropped (`generation`).
@MainActor
final class LeoBrowserFindController {
    private let finder: any LeoPageFinding
    private weak var view: NSView?
    private var isLoading = false
    /// Counts every search, step and clear; only the latest one's answer applies.
    private var generation = 0
    private var pending: [Int: Task<Void, Never>] = [:]
    private var taskCount = 0

    private(set) var query = ""
    private(set) var isShown = false
    private(set) var result: LeoFindResult?
    /// Called after any change to what the bar shows.
    var onChange: () -> Void = {}

    init(finder: any LeoPageFinding) {
        self.finder = finder
    }

    /// "2 of 12", "No matches", "1 of 1000+"; empty with nothing typed.
    var labelText: String {
        guard !query.isEmpty, let result else { return "" }
        guard result.total > 0 else { return "No matches" }
        return "\(result.index) of \(result.total)\(result.isCapped ? "+" : "")"
    }

    /// Brings the bar up (⌘F). The last query comes back with it.
    func show() {
        guard !isShown else { return }
        isShown = true
        onChange()
        search()
    }

    /// Esc or Done: the marks go, the typed query stays for next time.
    func hide() {
        guard isShown else { return }
        isShown = false
        result = nil
        let old = view
        generation += 1
        track { [finder] in await finder.clear(in: old) }
        onChange()
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        search()
    }

    /// ⌘G / ⌘⇧G. With the bar down, this only brings it up.
    func step(_ direction: LeoFindDirection) {
        guard isShown else { return show() }
        guard !query.isEmpty else { return }
        perform { [finder, query, view] in await finder.step(direction, query: query, in: view) }
    }

    /// Edit ▸ Use Selection for Find: the page's selection becomes the query.
    func useSelection() async {
        guard let text = await finder.selectedText(in: view) else { return }
        query = text
        if isShown { search() } else { show() }
    }

    /// The pane's active page, or its loading state, changed. A new page loses
    /// the old one's marks; a page that finished loading is searched again.
    func pageChanged(to newView: NSView?, isLoading nowLoading: Bool) {
        let wasLoading = isLoading
        isLoading = nowLoading
        if newView !== view {
            let old = view
            view = newView
            generation += 1
            result = nil
            track { [finder] in await finder.clear(in: old) }
            onChange()
            if isShown { search() }
        } else if wasLoading, !nowLoading, isShown {
            search()
        }
    }

    /// Waits for every call to the page made so far; tests use it, the bar doesn't.
    func settled() async {
        while let task = pending.values.first { await task.value }
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        taskCount += 1
        let id = taskCount
        pending[id] = Task { [weak self] in
            await body()
            self?.pending[id] = nil
        }
    }

    private func search() {
        perform { [finder, query, view] in await finder.search(query, in: view) }
    }

    private func perform(_ body: @escaping @MainActor () async -> LeoFindResult) {
        generation += 1
        let mine = generation
        // Not chained: WebKit never answers a call made mid-navigation, and a
        // hung one must not hold up the next.
        track { [weak self] in
            let answer = await body()
            guard let self, mine == generation else { return }
            result = answer
            onChange()
        }
    }
}
