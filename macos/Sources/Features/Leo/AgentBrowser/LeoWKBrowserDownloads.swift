import Foundation
import LeoKit
import OSLog
import WebKit

/// An agent browser's WebKit downloads (B-404). Each `WKDownload` is
/// fetched into its own private folder under `temporaryRoot`; once it is
/// complete, `log` saves it into the agent's workspace (`downloads/`) and
/// the folder goes. A failed or cancelled fetch deletes its folder, so
/// nothing partial is left on this Mac or in the workspace. The log is
/// where the agent (`browser_downloads`) and the pane read each step.
@available(macOS 14, *)
@MainActor final class LeoWKBrowserDownloads: NSObject, WKDownloadDelegate {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "AgentBrowser")

    /// Where this app's browsers stage downloads: per bundle, so a debug
    /// build never sweeps a release build's files.
    nonisolated static var defaultTemporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LeoBrowserDownloads", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Leo", isDirectory: true)
    }

    /// Removes whatever an earlier run left under `root` (an app that quit
    /// mid-download). Called once at launch, before any browser exists.
    nonisolated static func sweep(_ root: URL = defaultTemporaryRoot) {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fetch {
        let id: Int
        let folder: URL
        let file: URL
        let progress: NSKeyValueObservation
    }

    let log: LeoBrowserDownloads
    private let temporaryRoot: URL
    private var fetches: [ObjectIdentifier: Fetch] = [:]
    /// Downloads not yet given a destination, so `cancel(for:)` reaches them too.
    private var pending: [ObjectIdentifier: WKDownload] = [:]

    init(log: LeoBrowserDownloads, temporaryRoot: URL = defaultTemporaryRoot) {
        self.log = log
        self.temporaryRoot = temporaryRoot
    }

    /// A navigation or response in one of the browser's tabs became `download`.
    func adopt(_ download: WKDownload) {
        download.delegate = self
        pending[ObjectIdentifier(download)] = download
    }

    /// The tab showing `webView` closed: its downloads still fetching stop
    /// and fail as cancelled. Ones already saving finish.
    func cancel(for webView: WKWebView) {
        pending.values.filter { $0.webView === webView }.forEach(stop)
    }

    /// The browser closed: every download still fetching stops.
    func cancelAll() {
        pending.values.forEach(stop)
    }

    /// Ends the fetch once WebKit has stopped writing, whether or not a
    /// failure callback follows.
    private func stop(_ download: WKDownload) {
        download.cancel { [weak self] _ in
            Task { @MainActor in self?.ended(download, reason: Self.cancelledReason) }
        }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        let id = log.begin(suggestedName: suggestedFilename, sourceURL: download.originalRequest?.url ?? response.url)
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Self.logger.error("download staging folder failed error=\(String(describing: error), privacy: .public)")
            pending[key] = nil
            log.fail(id, reason: "This Mac couldn’t make a place to download it.")
            return nil
        }
        let file = folder.appendingPathComponent(log.entries.first { $0.id == id }?.name ?? LeoBrowserDownloadName.fallback)
        let progress = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in self?.log.progress(id, receivedBytes: received, expectedBytes: total > 0 ? total : nil) }
        }
        fetches[key] = Fetch(id: id, folder: folder, file: file, progress: progress)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        pending[key] = nil
        guard let fetch = fetches.removeValue(forKey: key) else { return }
        fetch.progress.invalidate()
        Task {
            await log.complete(fetch.id, file: fetch.file)
            Self.remove(fetch.folder)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        ended(download, reason: Self.reason(for: error))
    }

    // MARK: - Helpers

    private static let cancelledReason = "it was cancelled."

    /// The fetch failed: its folder goes and the log says why. Only the
    /// first end counts.
    private func ended(_ download: WKDownload, reason: String) {
        let key = ObjectIdentifier(download)
        pending[key] = nil
        guard let fetch = fetches.removeValue(forKey: key) else { return }
        fetch.progress.invalidate()
        Self.remove(fetch.folder)
        log.fail(fetch.id, reason: reason)
    }

    private static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func reason(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return cancelledReason }
        return error.localizedDescription
    }
}
