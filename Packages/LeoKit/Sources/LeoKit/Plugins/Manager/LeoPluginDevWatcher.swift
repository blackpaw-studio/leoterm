import Foundation

/// Reports changes to a file or folder. The Mac app implements it with a
/// `DispatchSource`; tests drive a fake. The handler may run on any thread.
/// Returns nil when the path can't be watched (it doesn't exist yet).
public protocol LeoPluginFileEventSource: Sendable {
    func watch(_ url: URL, handler: @escaping @Sendable () -> Void) -> (any LeoPluginTimerHandle)?
}

/// Reloads a dev plugin when its files change. Watches the plugin folder, the
/// manifest, and `main` together with its folder: a directory watch sees an
/// atomic-rename write, a file watch sees an in-place one. Events inside the
/// debounce window collapse into one reload, and every watch is opened again
/// after a reload because a rename leaves the old one pointing at a dead file.
@MainActor public final class LeoPluginDevWatcher: LeoPluginDevWatching {
    public static let defaultDebounce: TimeInterval = 0.3

    private struct Watching {
        var urls: [URL]
        var handles: [any LeoPluginTimerHandle]
        var pending: (any LeoPluginTimerHandle)?
    }

    /// Called on the main actor with the plugin id, once per burst of changes.
    public var onChange: (@MainActor (String) -> Void)?

    private let source: any LeoPluginFileEventSource
    private let scheduler: any LeoPluginTimerScheduling
    private let debounce: TimeInterval
    private var targets: [String: Watching] = [:]

    public init(
        source: any LeoPluginFileEventSource, scheduler: any LeoPluginTimerScheduling, debounce: TimeInterval = defaultDebounce
    ) {
        self.source = source
        self.scheduler = scheduler
        self.debounce = debounce
    }

    public func sync(_ wanted: [LeoPluginDevTarget]) {
        let ids = Set(wanted.map(\.id))
        for id in targets.keys where !ids.contains(id) { remove(id) }
        for target in wanted {
            let urls = Self.unique(target.urls)
            if let existing = targets[target.id], existing.urls == urls { continue }
            remove(target.id)
            targets[target.id] = Watching(urls: urls, handles: arm(target.id, urls), pending: nil)
        }
    }

    public func stopAll() {
        for id in Array(targets.keys) { remove(id) }
    }

    // MARK: Private

    private func arm(_ id: String, _ urls: [URL]) -> [any LeoPluginTimerHandle] {
        urls.compactMap { url in
            source.watch(url) { [weak self] in
                Task { @MainActor in self?.eventArrived(id) }
            }
        }
    }

    private func eventArrived(_ id: String) {
        guard var watching = targets[id] else { return }
        watching.pending?.cancel()
        watching.pending = scheduler.schedule(after: debounce, repeating: false) { [weak self] in
            Task { @MainActor in self?.reload(id) }
        }
        targets[id] = watching
    }

    private func reload(_ id: String) {
        guard var watching = targets[id] else { return }
        watching.pending = nil
        watching.handles.forEach { $0.cancel() }
        watching.handles = arm(id, watching.urls)
        targets[id] = watching
        onChange?(id)
    }

    private func remove(_ id: String) {
        guard let watching = targets.removeValue(forKey: id) else { return }
        watching.pending?.cancel()
        watching.handles.forEach { $0.cancel() }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
