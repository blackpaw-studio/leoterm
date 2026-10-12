import Foundation

/// Quick retries while the first agent list has never landed: a cold launch
/// whose first fetch times out or is refused must not wait out the 30 s
/// disconnected poll with an empty list. Stops on success, a host switch,
/// a disconnect, hiding the sidebar, or `stop()`; once the list has loaded
/// the ordinary poll owns refreshing.
extension LeoSidebarFeed {
    /// Delay before retry N (0-based); the last entry repeats.
    static let baselineRetryBackoff: [TimeInterval] = [1, 2, 4, 8]

    func scheduleBaselineRetry() {
        guard running, selectedHostAvailable, pollingRequested, !wasLive, !isDisconnected else { return }
        let delay = Self.baselineRetryBackoff[min(baselineRetryAttempts, Self.baselineRetryBackoff.count - 1)]
        baselineRetryAttempts += 1
        baselineRetryTask?.cancel()
        baselineRetryTask = Task { [weak self, sleeper] in
            do {
                try await sleeper(UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.baselineRetryFired()
        }
    }

    func cancelBaselineRetry() {
        baselineRetryTask?.cancel()
        baselineRetryTask = nil
        baselineRetryAttempts = 0
    }

    private func baselineRetryFired() {
        baselineRetryTask = nil
        guard running, selectedHostAvailable, pollingRequested, !wasLive else { return }
        process(scheduler.reduce(.refreshRequested))
    }
}
