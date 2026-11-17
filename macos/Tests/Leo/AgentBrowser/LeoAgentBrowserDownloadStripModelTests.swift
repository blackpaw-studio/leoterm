import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-404: the browser pane's download strip -- progress, where a file was
/// saved, or plainly why it wasn't. A saved file's line goes by itself; a
/// failure stays until dismissed.
@MainActor
struct LeoAgentBrowserDownloadStripModelTests {
    /// Runs scheduled work only when the test says so.
    @MainActor private final class ManualSchedule {
        private(set) var delays: [Duration] = []
        private var actions: [@MainActor () -> Void] = []

        func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
            delays.append(delay)
            actions.append(action)
        }

        func runAll() {
            let pending = actions
            actions = []
            pending.forEach { $0() }
        }
    }

    private let source = FakePaneSource()
    private let schedule = ManualSchedule()

    private func model() -> LeoAgentBrowserPaneModel {
        LeoAgentBrowserPaneModel(source: source, schedule: schedule.schedule)
    }

    /// A log that saves into a throwaway workspace.
    private func savingLog() throws -> (LeoBrowserDownloads, LeoFileSandbox) {
        let workspace = try LeoFileSandbox()
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { workspace.root })
        return (log, workspace)
    }

    @Test func stripShowsProgressSavedAndFailureText() async throws {
        let (log, workspace) = try savingLog()
        defer { workspace.cleanUp() }
        source.downloads = log
        let model = model()
        #expect(model.downloadStrip == nil)

        let id = log.begin(suggestedName: "report.pdf", sourceURL: nil)
        #expect(model.downloadStrip?.text == "Downloading “report.pdf”…")
        #expect(model.downloadStrip?.kind == .downloading)
        #expect(model.downloadStrip?.progress == nil)

        log.progress(id, receivedBytes: 45, expectedBytes: 100)
        #expect(model.downloadStrip?.text == "Downloading “report.pdf”… 45%")
        #expect(model.downloadStrip?.progress == 0.45)

        let file = try workspace.file("fetched", "%PDF")
        await log.complete(id, file: URL(fileURLWithPath: file))
        #expect(model.downloadStrip?.text == "Saved “report.pdf” to downloads/")
        #expect(model.downloadStrip?.kind == .finished)

        let failed = log.begin(suggestedName: "big.zip", sourceURL: nil)
        log.fail(failed, reason: "The network connection was lost.")
        #expect(model.downloadStrip?.text == "Couldn’t download “big.zip”. The download failed: The network connection was lost. Nothing was saved.")
        #expect(model.downloadStrip?.kind == .failed)
    }

    @Test func finishedAutoHidesFailureStays() async throws {
        let (log, workspace) = try savingLog()
        defer { workspace.cleanUp() }
        source.downloads = log
        let model = model()

        let failed = log.begin(suggestedName: "a.zip", sourceURL: nil)
        log.fail(failed, reason: "gone")
        let saved = log.begin(suggestedName: "b.txt", sourceURL: nil)
        await log.complete(saved, file: URL(fileURLWithPath: try workspace.file("fetched", "b")))
        #expect(model.downloadStrip?.id == saved)
        #expect(schedule.delays == [LeoAgentBrowserPaneModel.finishedDownloadDuration])

        schedule.runAll()
        #expect(model.downloadStrip?.id == failed, "the failure is still there once the saved line goes")

        model.dismissDownload()
        #expect(model.downloadStrip == nil)
        #expect(schedule.delays.count == 1, "a failure never hides by itself")
    }

    @Test func eachOutcomeIsAnnouncedOnce() async throws {
        let (log, workspace) = try savingLog()
        defer { workspace.cleanUp() }
        source.downloads = log
        let model = model()
        var announcements: [String] = []
        model.onAnnouncement = { announcements.append($0) }

        let saved = log.begin(suggestedName: "b.txt", sourceURL: nil)
        log.progress(saved, receivedBytes: 1, expectedBytes: 2)
        await log.complete(saved, file: URL(fileURLWithPath: try workspace.file("fetched", "b")))
        let failed = log.begin(suggestedName: "a.zip", sourceURL: nil)
        log.fail(failed, reason: "gone")
        source.changed()

        #expect(announcements == [
            "Saved “b.txt” to downloads/",
            "Couldn’t download “a.zip”. The download failed: gone. Nothing was saved.",
        ])
    }

    @Test func downloadsThatEndedBeforeThePaneOpenedOnlyShowFailures() async throws {
        let (log, workspace) = try savingLog()
        defer { workspace.cleanUp() }
        source.downloads = log
        let failed = log.begin(suggestedName: "a.zip", sourceURL: nil)
        log.fail(failed, reason: "gone")
        let saved = log.begin(suggestedName: "b.txt", sourceURL: nil)
        await log.complete(saved, file: URL(fileURLWithPath: try workspace.file("fetched", "b")))

        let model = model()

        #expect(model.downloadStrip?.id == failed)
        #expect(schedule.delays.isEmpty)
    }

    @Test func thePaneShowsTheStripAndItsCloseButtonDismissesIt() async {
        let pane = LeoAgentBrowserPaneViewController(source: source)
        _ = pane.view
        #expect(pane.downloadStrip.isHidden)

        let id = source.downloads.begin(suggestedName: "a.zip", sourceURL: nil)
        source.downloads.fail(id, reason: "gone")
        await drainMainQueue()
        #expect(!pane.downloadStrip.isHidden)
        #expect(pane.downloadStrip.label.stringValue == "Couldn’t download “a.zip”. The download failed: gone. Nothing was saved.")
        #expect(pane.downloadStrip.accessibilityLabel() == pane.downloadStrip.label.stringValue)

        pane.downloadStrip.dismissButton.performClick(nil)
        await drainMainQueue()
        #expect(pane.downloadStrip.isHidden)
    }

    // MARK: - File-menu saves (B-406)

    @Test func aMenuSaveShowsSavingThenSavedAndGoesAfterItsTime() {
        let model = model()
        var said: [String] = []
        model.onAnnouncement = { said.append($0) }

        let id = model.beginCapture(name: "Docs.pdf")
        #expect(model.downloadStrip == .init(id: id, kind: .saving, text: "Saving “Docs.pdf”…", progress: nil))

        let saved = LeoBrowserSavedDownload(path: "/ws/reports/Docs 2.pdf", workspacePath: "reports/Docs 2.pdf", size: 3)
        model.finishCapture(id, name: "Docs.pdf", outcome: .success(saved))
        #expect(model.downloadStrip == .init(id: id, kind: .finished, text: "Saved “Docs 2.pdf” to reports/", progress: nil))
        #expect(said == ["Saved “Docs 2.pdf” to reports/"])
        #expect(schedule.delays == [LeoAgentBrowserPaneModel.finishedDownloadDuration])

        schedule.runAll()
        #expect(model.downloadStrip == nil)
    }

    @Test func aSaveIntoTheWorkspaceItselfSaysSo() {
        let model = model()
        let id = model.beginCapture(name: "a.pdf")
        model.finishCapture(id, name: "a.pdf", outcome: .success(LeoBrowserSavedDownload(path: "/ws/a.pdf", workspacePath: "a.pdf", size: 1)))
        #expect(model.downloadStrip?.text == "Saved “a.pdf” to the workspace")
    }

    @Test func aFailedSaveStaysUntilDismissed() {
        let model = model()
        let id = model.beginCapture(name: "a.pdf")
        model.finishCapture(id, name: "a.pdf", outcome: .failure(LeoBrowserError(.jsError, "The PDF couldn’t be made: gone.")))

        #expect(model.downloadStrip?.kind == .failed)
        #expect(model.downloadStrip?.text == "Couldn’t save “a.pdf”. The PDF couldn’t be made: gone. Nothing was saved.")
        schedule.runAll()
        #expect(model.downloadStrip?.kind == .failed)
        model.dismissDownload()
        #expect(model.downloadStrip == nil)
    }

    @Test func aDismissedSavingLineStillReportsItsOutcome() {
        let model = model()
        let id = model.beginCapture(name: "a.pdf")
        model.dismissDownload()
        #expect(model.downloadStrip == nil)

        model.finishCapture(id, name: "a.pdf", outcome: .failure(LeoBrowserError(.saveFailed, "The connection to the machine was lost. Nothing was saved.")))
        #expect(model.downloadStrip?.text == "Couldn’t save “a.pdf”. The connection to the machine was lost. Nothing was saved.")
    }

    @Test func aNewerDownloadTakesTheStripFromASave() async throws {
        let (log, workspace) = try savingLog()
        defer { workspace.cleanUp() }
        source.downloads = log
        let model = model()
        let older = log.begin(suggestedName: "old.bin", sourceURL: nil)

        let id = model.beginCapture(name: "a.pdf")
        log.progress(older, receivedBytes: 1, expectedBytes: 2)
        #expect(model.downloadStrip?.id == id, "an older download's progress doesn't take the line")

        log.begin(suggestedName: "new.bin", sourceURL: nil)
        #expect(model.downloadStrip?.text == "Downloading “new.bin”…")
    }
}
