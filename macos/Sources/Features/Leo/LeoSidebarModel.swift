import AppKit
import Combine

/// App-owned model backing the Leo sidebar: holds the shared agent store, the
/// sidebar's visibility, and a poll timer that runs only while the sidebar is
/// visible (the daemon has no event stream, so the roster is polled).
@MainActor
final class LeoSidebarModel: ObservableObject {
    @Published var isVisible: Bool = false
    let store: LeoAgentStore
    private var pollTask: Task<Void, Never>?

    init(store: LeoAgentStore) { self.store = store }

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { startPolling() } else { stopPolling() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.store.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
