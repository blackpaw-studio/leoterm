import Foundation
import Testing

@testable import LeoKit

/// Hands out watches and lets the test emit events for a URL.
private final class FakeEvents: LeoPluginFileEventSource, @unchecked Sendable {
    private final class Watch: LeoPluginTimerHandle, @unchecked Sendable {
        let url: URL
        let handler: @Sendable () -> Void
        var isCancelled = false
        init(url: URL, handler: @escaping @Sendable () -> Void) {
            self.url = url
            self.handler = handler
        }
        func cancel() { isCancelled = true }
    }

    private let lock = NSLock()
    private var watches: [Watch] = []
    var unwatchable: Set<String> = []

    func watch(_ url: URL, handler: @escaping @Sendable () -> Void) -> (any LeoPluginTimerHandle)? {
        guard !unwatchable.contains(url.path) else { return nil }
        let watch = Watch(url: url, handler: handler)
        lock.withLock { watches.append(watch) }
        return watch
    }

    var liveURLs: [String] { lock.withLock { watches.filter { !$0.isCancelled }.map(\.url.path).sorted() } }

    func emit(_ path: String) {
        let live = lock.withLock { watches.filter { !$0.isCancelled && $0.url.path == path } }
        live.forEach { $0.handler() }
    }
}

@MainActor struct LeoPluginDevWatcherTests {
    private let folder = URL(fileURLWithPath: "/dev/plugin")

    private func target(_ id: String = "studio.blackpaw.dev") -> LeoPluginDevTarget {
        LeoPluginDevTarget(id: id, urls: [
            folder, folder.appendingPathComponent("leo-plugin.json"), folder.appendingPathComponent("dist"),
            folder.appendingPathComponent("dist/main.js"), folder.appendingPathComponent("dist"),   // a duplicate on purpose
        ])
    }

    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    @Test func aBurstOfWritesProducesOneReloadAfterTheDebounce() async {
        let events = FakeEvents()
        let scheduler = PluginManualScheduler()
        let watcher = LeoPluginDevWatcher(source: events, scheduler: scheduler)
        var changed: [String] = []
        watcher.onChange = { changed.append($0) }
        watcher.sync([target()])

        for _ in 0..<6 { events.emit("/dev/plugin/dist/main.js") }
        events.emit("/dev/plugin/dist")
        await settle()
        #expect(changed.isEmpty)                         // still debouncing
        #expect(scheduler.liveDelays == [0.3])           // one pending reload, however many events

        scheduler.fireAll()
        await settle()
        #expect(changed == ["studio.blackpaw.dev"])
    }

    @Test func eachPathIsWatchedOnceAndTheWatchIsRearmedAfterAReload() async {
        let events = FakeEvents()
        let scheduler = PluginManualScheduler()
        let watcher = LeoPluginDevWatcher(source: events, scheduler: scheduler)
        watcher.onChange = { _ in }
        watcher.sync([target()])
        #expect(events.liveURLs == ["/dev/plugin", "/dev/plugin/dist", "/dev/plugin/dist/main.js", "/dev/plugin/leo-plugin.json"])

        // An atomic-rename write replaces the file: the old watch is stale, a new one is opened.
        events.emit("/dev/plugin/dist/main.js")
        await settle()
        scheduler.fireAll()
        await settle()
        #expect(events.liveURLs == ["/dev/plugin", "/dev/plugin/dist", "/dev/plugin/dist/main.js", "/dev/plugin/leo-plugin.json"])
    }

    @Test func aFileThatIsMissingWhenWatchedIsPickedUpAtTheNextEvent() async {
        let events = FakeEvents()
        events.unwatchable = ["/dev/plugin/dist/main.js"]
        let scheduler = PluginManualScheduler()
        let watcher = LeoPluginDevWatcher(source: events, scheduler: scheduler)
        watcher.onChange = { _ in }
        watcher.sync([target()])
        #expect(!events.liveURLs.contains("/dev/plugin/dist/main.js"))

        events.unwatchable = []
        events.emit("/dev/plugin/dist")      // the directory changed: the bundle appeared
        await settle()
        scheduler.fireAll()
        await settle()
        #expect(events.liveURLs.contains("/dev/plugin/dist/main.js"))
    }

    @Test func removingATargetStopsItsWatchesAndAPendingReload() async {
        let events = FakeEvents()
        let scheduler = PluginManualScheduler()
        let watcher = LeoPluginDevWatcher(source: events, scheduler: scheduler)
        var changed: [String] = []
        watcher.onChange = { changed.append($0) }
        watcher.sync([target()])
        events.emit("/dev/plugin/dist/main.js")
        await settle()

        watcher.sync([])
        scheduler.fireAll()
        await settle()

        #expect(events.liveURLs.isEmpty)
        #expect(changed.isEmpty)
    }

    @Test func syncingTheSameTargetsKeepsTheExistingWatches() {
        let events = FakeEvents()
        let watcher = LeoPluginDevWatcher(source: events, scheduler: PluginManualScheduler())
        watcher.sync([target()])
        let before = events.liveURLs
        watcher.sync([target()])
        #expect(events.liveURLs == before)
    }
}
