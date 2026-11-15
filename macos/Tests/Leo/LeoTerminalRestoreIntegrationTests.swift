import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-332: a window's Terminals rows saved through AppKit state restoration
/// and restored at launch -- their order, titles, split layouts and
/// working directories -- against real controllers and hosts. The restore
/// runs `LeoTerminalWindowRestoration`'s own decoding, into a window built
/// as `LeoRowLayoutFixture` builds one (the app's own restore path is off
/// in a test host).
@MainActor @Suite(.serialized) struct LeoTerminalRestoreIntegrationTests {
    private typealias Fixture = LeoRowLayoutFixture

    /// Three rows: the first renamed, in a directory deleted before the
    /// restore; the second split down (⇧⌘D) and selected, focused on its
    /// split; the third closed. The restored window lists the first two in
    /// order with the same titles, shows the second's layout focused as it
    /// was and keeps the first hidden; each shell starts in its saved
    /// directory, or home for the deleted one.
    @Test func restoresRowsLayoutTitlesAndCwd() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let (kept, gone) = (try Self.makeDirectory(), try Self.makeDirectory())
        defer { [kept, gone].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let renamed = try fixture.newRow()
        fixture.host.renameTerminal(renamed, to: "Renamed")
        let splitRow = try fixture.newRow()
        let splitRowView = try #require(fixture.view(splitRow))
        let split = try #require(fixture.split(splitRowView, .down))
        let closed = try fixture.newRow()
        #expect(fixture.host.reveal(splitRow))
        fixture.host.closeTerminal(closed)
        fixture.controller.focusedSurface = split
        let renamedView = try #require(fixture.kept().first { $0.id == renamed.surfaceID })
        renamedView.pwd = gone
        [splitRowView, split].forEach { $0.pwd = kept }
        try FileManager.default.removeItem(atPath: gone)
        let titles = [renamedView.title, splitRowView.title, split.title]
        let window = try #require(fixture.controller.window)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        fixture.controller.window(window, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
        fixture.close()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        var restored: Fixture?
        let (restoredWindow, error) = LeoTerminalWindowRestoration.restore(from: unarchiver, windowSaveState: "default") { state in
            guard let fixture = try? Fixture(startScreen: true) else { return nil }
            restored = fixture
            return fixture.host.restoreTerminalRows(state.rows, selecting: state.selectedRow, in: fixture.controller) == nil ? nil : fixture.controller.window
        }
        unarchiver.finishDecoding()
        let after = try #require(restored)
        defer { after.close() }

        #expect(error == nil)
        #expect(restoredWindow === after.controller.window)
        #expect(after.terminals.rows.map(\.id) == [renamed.surfaceID, splitRow.surfaceID])
        #expect(after.terminals.rows.map(\.title) == ["Renamed", titles[1]])
        #expect(after.terminals.selection == splitRow.surfaceID)
        #expect(after.shown().map(\.id) == [splitRow.surfaceID, split.id])
        #expect(after.shown().map(\.title) == Array(titles[1...]))
        #expect(after.rootSplit?.direction == .vertical, "split down")
        #expect(after.controller.focusedSurface?.id == split.id)
        let hidden = try #require(after.kept().first { $0.id == renamed.surfaceID })
        #expect(after.kept().map(\.id) == [renamed.surfaceID], "the first row is kept hidden, alone")
        #expect(hidden.leoTitleIsUserSet)
        #expect(after.host.isOpen(after.handle(hidden)) && !after.host.isShown(after.handle(hidden)))
        #expect(hidden.leoStartWorkingDirectory == NSHomeDirectory(), "its directory is gone")
        #expect(after.shown().map(\.leoStartWorkingDirectory) == [kept, kept])
    }

    /// `window-save-state = never`: nothing is decoded and no window opens.
    @Test func neverRestoresNothing() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try fixture.newRow()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: Self.encode(fixture))
        defer { unarchiver.finishDecoding() }
        var opened = false

        let (window, error) = LeoTerminalWindowRestoration.restore(from: unarchiver, windowSaveState: "never") { _ in
            opened = true
            return nil
        }

        #expect(window == nil && error == nil)
        #expect(!opened)
    }

    /// A window listing no Terminals row saves nothing to restore: it isn't
    /// restorable, and its state restores no window. One listing a row is
    /// -- though never in a test host, whose windows are the debug app's.
    @Test func windowWithoutRowsIsNotRestorable() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        #expect(!fixture.controller.leoHasRestorableTerminals)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: Self.encode(fixture))
        defer { unarchiver.finishDecoding() }
        var opened = false

        let (window, error) = LeoTerminalWindowRestoration.restore(from: unarchiver, windowSaveState: "default") { _ in
            opened = true
            return nil
        }

        #expect(window == nil && error == nil && !opened)
        let row = try fixture.newRow()
        #expect(fixture.controller.leoHasRestorableTerminals)
        #expect(fixture.controller.window?.isRestorable == false, "a test host's window is never saved")
        fixture.host.closeTerminal(row)
        #expect(!fixture.controller.leoHasRestorableTerminals)
    }

    private static func encode(_ fixture: Fixture) throws -> Data {
        let window = try #require(fixture.controller.window)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        fixture.controller.window(window, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// A new directory, by its real path (`/private/var/...`, not the
    /// `/var` symlink), as a shell reports it.
    private static func makeDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.resolvingSymlinksInPath().path
    }
}
