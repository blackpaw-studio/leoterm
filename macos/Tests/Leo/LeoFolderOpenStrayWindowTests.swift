import AppKit
import CoreGraphics
import Testing

@testable import Ghostty

/// B-142: opening a folder -- Finder, the Dock, `open -a Leo <dir>`, all of
/// which reach `application(_:openFile:)` -- opens the folder's terminal
/// window and no window of Leo's besides.
///
/// B-093's verify found an untitled 500x500 window with no accessibility
/// element at the screen's bottom-left after every folder-open. It is
/// macOS's text-input cursor window (`TUINSWindow`), not Leo's: the first
/// time any text input is active in the key window -- the folder's
/// terminal, File ▸ New Terminal's, a search field -- AppKit's
/// `NSTextInputContext.activate` makes it, once per process, through
/// `TUINSCursorUIController.sharedInstance`. It stays ordered out until the
/// system shows its caps-lock or input-source indicator at the insertion
/// point, and every Mac app that takes text has one. A plain launch shows
/// the start screen, which takes no text, so only a terminal brought it.
///
/// Each test diffs the app's windows -- AppKit's list and the window
/// server's, which also holds windows AppKit doesn't list -- across one
/// folder-open and names every window it can't account for: its class,
/// frame, controller and content. Folders only: opening a file asks first,
/// with a modal alert a test must never run. The window runs the default
/// shell, never an agent; each test closes the windows it opened, with undo
/// registration off while they open.
@MainActor @Suite(
    .serialized,
    .enabled("needs the app's Ghostty.App") { await MainActor.run { hasLiveGhosttyApp } },
    LeoCascadePointRestoringTrait()
)
struct LeoFolderOpenStrayWindowTests {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// How long a step may take to settle on a loaded host.
    private static let settleTimeout: Duration = .seconds(30)

    /// Once the windows settle, how long a window something opens later (on
    /// a timer, say) has to turn up before the diff.
    private static let lateWindowGrace: Duration = .seconds(1)

    /// The size of the window B-093's verify found.
    private static let reportedStraySize = CGSize(width: 500, height: 500)

    /// Where the system's private text-input UI frameworks live.
    private static let textInputUIFrameworkPrefix = "/System/Library/PrivateFrameworks/TextInputUI"

    private func liveApp() throws -> AppDelegate {
        try #require(Self.app)
    }

    private func withoutUndo<T>(_ app: AppDelegate, _ body: () throws -> T) rethrows -> T {
        app.undoManager.disableUndoRegistration()
        defer { app.undoManager.enableUndoRegistration() }
        return try body()
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Waits until no presentation `controllers` queued is still pending and
    /// a whole main-queue turn after that changed none of their windows,
    /// then gives a late window `lateWindowGrace` to appear. False if they
    /// never settle within the timeout.
    private func settle(_ controllers: [TerminalController]) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.settleTimeout
        var previous: [NSRect?]?
        var isSettled = false
        while !isSettled, ContinuousClock.now < deadline {
            await nextMainQueueTurn()
            let current = controllers.map { $0.window.map { $0.isVisible ? $0.frame : .zero } }
            isSettled = !controllers.contains(where: \.leoIsAwaitingPresentation) && current == previous
            previous = current
        }
        guard isSettled else { return false }
        try await Task.sleep(for: Self.lateWindowGrace)
        await nextMainQueueTurn()
        return true
    }

    /// Closes each controller's window, shown or not, unless it closed.
    private func close(_ controllers: [TerminalController]) {
        controllers.filter { !$0.leoWindowDidClose }.compactMap(\.window).forEach { $0.close() }
    }

    /// A Leo start-screen window, shown and settled, as a running app has.
    private func openStartScreenWindow(_ app: AppDelegate) async throws -> TerminalController {
        let window = withoutUndo(app) { TerminalController.leoNewPlaceholderWindow(app.ghostty) }
        let isSettled = try await settle([window])
        if !isSettled { close([window]) }
        try #require(isSettled, "the start-screen window's presentation never settled")
        return window
    }

    /// The system's text-input cursor window (see the suite's comment): its
    /// class comes from a private TextInputUI framework, never from Leo.
    private static func isSystemTextInputCursorWindow(_ window: NSWindow) -> Bool {
        Bundle(for: type(of: window)).bundlePath.hasPrefix(textInputUIFrameworkPrefix)
    }

    /// The app's windows, AppKit's and the window server's, at one moment.
    private struct Inventory {
        let windows: [NSWindow]
        let serverWindows: [ServerWindow]

        @MainActor static func now() -> Inventory {
            Inventory(windows: NSApp.windows, serverWindows: ServerWindow.ownedByThisProcess())
        }
    }

    /// One window-server window this process owns.
    private struct ServerWindow: CustomStringConvertible {
        let number: Int
        let bounds: CGRect
        let layer: Int
        let name: String?
        let isOnScreen: Bool
        let alpha: Double

        var description: String {
            "server window #\(number) bounds=\(bounds) layer=\(layer) onScreen=\(isOnScreen) "
                + "alpha=\(alpha) name=\(name.map { "\"\($0)\"" } ?? "nil")"
        }

        static func ownedByThisProcess() -> [ServerWindow] {
            let pid = Int(getpid())
            let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
            return infos.compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? Int) == pid,
                      let number = info[kCGWindowNumber as String] as? Int else { return nil }
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .null
                return ServerWindow(
                    number: number,
                    bounds: bounds,
                    layer: info[kCGWindowLayer as String] as? Int ?? 0,
                    name: info[kCGWindowName as String] as? String,
                    isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    alpha: info[kCGWindowAlpha as String] as? Double ?? 1
                )
            }
        }
    }

    /// One folder-open: the windows before it, the terminal windows it
    /// made, and the windows once those settled.
    private struct FolderOpen {
        let before: Inventory
        let opened: [TerminalController]
        let after: Inventory
    }

    /// Opens a fresh folder as Finder or the Dock would and waits for what
    /// it opened to settle.
    private func openFolder(_ app: AppDelegate, _ folder: URL) async throws -> FolderOpen {
        let before = Inventory.now()
        let existing = Set(TerminalController.all.map(ObjectIdentifier.init))
        let isHandled = withoutUndo(app) { app.application(NSApp, openFile: folder.path) }
        let opened = TerminalController.all.filter { !existing.contains(ObjectIdentifier($0)) }
        #expect(isHandled)
        let isSettled = try await settle(opened)
        if !isSettled { close(opened) }
        try #require(isSettled, "the folder's window never settled")
        return FolderOpen(before: before, opened: opened, after: Inventory.now())
    }

    /// `window` is one of `opened`'s, or hangs off one (a child window or a
    /// sheet).
    private func belongs(_ window: NSWindow, to opened: [TerminalController]) -> Bool {
        let ownWindows = Set(opened.compactMap(\.window).map(ObjectIdentifier.init))
        let ancestry = sequence(first: window) { $0.parent ?? $0.sheetParent }
        return ancestry.contains { ownWindows.contains(ObjectIdentifier($0)) }
    }

    /// The AppKit windows the open added that it can't account for. It
    /// accounts for the folder's terminal window and what hangs off it, the
    /// agent palette panel each Leo window builds up front (ordered out
    /// until the palette opens, when it becomes the window's child), one
    /// per window opened, and the system's text-input cursor window.
    private func strayWindows(_ open: FolderOpen) -> [NSWindow] {
        let before = Set(open.before.windows.map(ObjectIdentifier.init))
        let unaccounted = open.after.windows
            .filter { !before.contains(ObjectIdentifier($0)) }
            .filter { !belongs($0, to: open.opened) && !Self.isSystemTextInputCursorWindow($0) }
        let palettePanels = unaccounted.filter { $0 is LeoAgentPalettePanel }
        return unaccounted.filter { !($0 is LeoAgentPalettePanel) } + palettePanels.dropFirst(open.opened.count)
    }

    /// The window-server windows the open added that no AppKit window
    /// accounts for, or that are the reported stray's size and not the
    /// system's text-input cursor window (nor the folder's own).
    private func strayServerWindows(_ open: FolderOpen) -> [ServerWindow] {
        let before = Set(open.before.serverWindows.map(\.number))
        let appKitWindows = Dictionary(open.after.windows.map { ($0.windowNumber, $0) }) { first, _ in first }
        return open.after.serverWindows
            .filter { !before.contains($0.number) }
            .filter { server in
                guard let window = appKitWindows[server.number] else { return true }
                return server.bounds.size == Self.reportedStraySize
                    && !Self.isSystemTextInputCursorWindow(window) && !belongs(window, to: open.opened)
            }
    }

    /// Everything a failure needs to name a window and what made it.
    private func describe(_ window: NSWindow) -> String {
        let controller = window.windowController.map { String(describing: type(of: $0)) } ?? "nil"
        let content = window.contentView.map { String(describing: type(of: $0)) } ?? "nil"
        let parent = window.parent.map { "#\($0.windowNumber) \(type(of: $0))" } ?? "nil"
        return "\(type(of: window)) #\(window.windowNumber) frame=\(window.frame) visible=\(window.isVisible) "
            + "level=\(window.level.rawValue) title=\"\(window.title)\" controller=\(controller) "
            + "content=\(content) parent=\(parent) bundle=\(Bundle(for: type(of: window)).bundlePath)"
    }

    private func report(_ windows: [NSWindow]) -> Comment {
        Comment(rawValue: "stray windows:\n" + windows.map(describe).joined(separator: "\n"))
    }

    private func report(_ windows: [ServerWindow]) -> Comment {
        Comment(rawValue: "unaccounted server windows:\n" + windows.map(\.description).joined(separator: "\n"))
    }

    private func makeFolder() -> LeoReservedTestDirectory {
        LeoReservedTestDirectory(template: NSTemporaryDirectory() + "leo-b142-XXXXXX")
    }

    @Test func openingAFolderCreatesNoWindowButItsTerminalWindow() async throws {
        let app = try liveApp()
        let folder = makeFolder()
        defer { folder.removeIfReserved() }

        let open = try await openFolder(app, folder.reserve())
        defer { close(open.opened) }

        #expect(open.opened.count == 1)
        let strays = strayWindows(open)
        #expect(strays.isEmpty, report(strays))
    }

    @Test func openingAFolderAddsNoUnaccountedServerWindow() async throws {
        let app = try liveApp()
        let folder = makeFolder()
        defer { folder.removeIfReserved() }

        let open = try await openFolder(app, folder.reserve())
        defer { close(open.opened) }

        let strays = strayServerWindows(open)
        #expect(strays.isEmpty, report(strays))
    }

    /// The running app's path: a Leo window is already open, so the folder's
    /// window has a parent to open from (`newTab`).
    @Test func openingAFolderWhileAWindowIsOpenCreatesNoStrayWindow() async throws {
        let app = try liveApp()
        let existing = try await openStartScreenWindow(app)
        defer { close([existing]) }
        let folder = makeFolder()
        defer { folder.removeIfReserved() }

        let open = try await openFolder(app, folder.reserve())
        defer { close(open.opened) }

        let strays = strayWindows(open)
        let serverStrays = strayServerWindows(open)
        #expect(strays.isEmpty, report(strays))
        #expect(serverStrays.isEmpty, report(serverStrays))
    }

    /// The cold launch's path: the folder's window replaces an untouched
    /// launch window (D-149), which closes; only the windows the open added
    /// count.
    @Test func openingAFolderOverTheLaunchWindowCreatesNoStrayWindow() async throws {
        let app = try liveApp()
        let launch = try await openStartScreenWindow(app)
        defer { close([launch]) }
        app.leoLaunchPlaceholder.adopt(launch)
        let folder = makeFolder()
        defer { folder.removeIfReserved() }

        let open = try await openFolder(app, folder.reserve())
        defer { close(open.opened) }

        let strays = strayWindows(open)
        let serverStrays = strayServerWindows(open)
        #expect(strays.isEmpty, report(strays))
        #expect(serverStrays.isEmpty, report(serverStrays))
        #expect(launch.leoWindowDidClose, "the launch window gave way to the folder's")
    }
}

/// The app has a real `Ghostty.App` to make surfaces with.
@MainActor private var hasLiveGhosttyApp: Bool {
    (NSApp.delegate as? AppDelegate)?.ghostty.app != nil
}
