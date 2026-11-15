import Foundation

/// A live reading of a cron expression as it is typed: waits out the
/// debounce, then asks the daemon about the latest expression only. Every call
/// supersedes the one before it, so an answer for an older expression never
/// comes back.
public actor LeoCronPreviewer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Fetch = @Sendable (String) async throws -> LeoCronPreview

    public static let defaultDebounce = Duration.milliseconds(400)

    private let debounce: Duration
    private let sleep: Sleep
    private let fetch: Fetch
    private var latest = 0

    public init(debounce: Duration = LeoCronPreviewer.defaultDebounce, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, fetch: @escaping Fetch) {
        self.debounce = debounce
        self.sleep = sleep
        self.fetch = fetch
    }

    /// The reading of `expression`, or nil when there is nothing to show: it
    /// is blank, a newer call (or a cancel) superseded this one, or the daemon
    /// couldn't answer.
    public func preview(_ expression: String) async -> LeoCronPreviewResult? {
        latest += 1
        let mine = latest
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do { try await sleep(debounce) } catch { return nil }
        guard mine == latest else { return nil }
        let reply: LeoCronPreview
        do { reply = try await fetch(trimmed) } catch { return nil }
        guard mine == latest, !Task.isCancelled else { return nil }
        return reply.valid ? .valid(reply.description) : .invalid(reply.error ?? "Not a valid schedule.")
    }
}
