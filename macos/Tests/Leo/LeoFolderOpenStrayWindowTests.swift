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
/// macOS's text-input cursor window, TextInputUIMacHelper's `TUINSWindow`,
/// not Leo's: `TUINSCursorUIController.sharedInstance` makes it once per
/// process, the first time an input context activates
/// (`NSTextInputContext.activate`, from `NSApplication.updateWindows`) --
/// here the folder's terminal; File ▸ New Terminal's or a search field's
/// would do the same. It stays ordered out, hosting the system's caps-lock
/// and input-source indicator. A plain launch shows the start screen,
/// which activates no input context, so it has none.
///
/// Each test diffs the app's windows -- AppKit's list and the window
/// server's -- across one folder-open and names every window it can't
/// account for. Suites share this app, so other suites may open windows
/// while a test waits for the folder's window to present. The diff
/// attributes by cause:
/// - A window that appeared while `application(_:openFile:)` ran is the
///   open's (the test never yields the main actor then). It must be the
///   folder's window, its own palette panel, a child or sheet of the
///   folder's window, or the system's text-input cursor window.
/// - A window that appeared later is another suite's when it is, or hangs
///   off, another terminal controller's window or that controller's
///   palette panel, or hangs off a bare `NSWindow` (only tests build those
///   here). Any other one counts as the open's.
/// - Of the open's windows, any 500x500 one, and any invisible one at the
///   screen origin other than the folder window's own palette panel, is
///   a stray even as a child or sheet of the folder's window.
///
/// Folders only: opening a file asks first, with a modal alert a test must
/// never run. The window runs the default shell, never an agent; each test
/// closes the windows it opened, with undo registration off while they
/// open.
@MainActor @Suite(
    .serialized,
    .enabled("needs the app's Ghostty.App") { await MainActor.run { hasLiveGhosttyApp } },
    LeoCascadePointRestoringTrait()
)
struct LeoFolderOpenStrayWindowTests {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// How long a step may take to settle on a loaded host.
    private static let settleTimeout: Duration = .seconds(30)

    /// The size of the window B-093's verify found.
    private static let reportedStraySize = CGSize(width: 500, height: 500)

    /// The system's text-input cursor window: its class, and the private
    /// framework that class comes from.
    private static let textInputCursorWindowClass = "TUINSWindow"
    private static let textInputCursorFramework = "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework"

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
    /// a whole main-queue turn after that changed none of their windows. By
    /// then what those presentations queued (the cascade, a replaced launch
    /// window's close) has run too. False if that never happens within the
    /// timeout.
    private func settle(_ controllers: [TerminalController]) async -> Bool {
        let deadline = ContinuousClock.now + Self.settleTimeout
        var previous: [NSRect?]?
        while ContinuousClock.now < deadline {
            await nextMainQueueTurn()
            let current = controllers.map { $0.window.map { $0.isVisible ? $0.frame : .zero } }
            if !controllers.contains(where: \.leoIsAwaitingPresentation), current == previous { return true }
            previous = current
        }
        return false
    }

    /// Closes each controller's window, shown or not, unless it closed.
    private func close(_ controllers: [TerminalController]) {
        controllers.filter { !$0.leoWindowDidClose }.compactMap(\.window).forEach { $0.close() }
    }

    /// A Leo start-screen window, shown and settled, as a running app has.
    private func openStartScreenWindow(_ app: AppDelegate) async throws -> TerminalController {
        let window = withoutUndo(app) { TerminalController.leoNewPlaceholderWindow(app.ghostty) }
        let isSettled = await settle([window])
        if !isSettled { close([window]) }
        try #require(isSettled, "the start-screen window's presentation never settled")
        return window
    }

    private static func isSystemTextInputCursorWindow(_ window: NSWindow) -> Bool {
        let windowClass: AnyClass = type(of: window)
        return NSStringFromClass(windowClass) == textInputCursorWindowClass
            && Bundle(for: windowClass).bundlePath == textInputCursorFramework
    }

    /// One window-server window this process owns.
    private struct ServerWindow: CustomStringConvertible {
        let number: Int
        let bounds: CGRect
        let layer: Int
        let isOnScreen: Bool

        var description: String {
            "server window #\(number) bounds=\(bounds) layer=\(layer) onScreen=\(isOnScreen)"
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
                    isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false
                )
            }
        }
    }

    /// One folder-open: the app's windows before it, the windows it added
    /// while it ran (its own, whatever they are), the terminal windows it
    /// made, and the app's windows once those settled.
    private struct FolderOpen {
        let windowsBefore: [NSWindow]
        let serverWindowsBefore: [ServerWindow]
        let windowsAddedDuringCall: [NSWindow]
        let opened: [TerminalController]
        let windowsAfter: [NSWindow]
        let serverWindowsAfter: [ServerWindow]
    }

    /// Opens a fresh folder as Finder or the Dock would and waits until it
    /// and `watching` (a launch window it may replace) settle.
    private func openFolder(
        _ app: AppDelegate, _ folder: URL, watching: [TerminalController] = []
    ) async throws -> FolderOpen {
        let windowsBefore = NSApp.windows
        let serverWindowsBefore = ServerWindow.ownedByThisProcess()
        let existing = Set(TerminalController.all.map(ObjectIdentifier.init))
        // No suspension from here to `windowsAddedDuringCall`: no other
        // suite can add a window in between.
        let isHandled = withoutUndo(app) { app.application(NSApp, openFile: folder.path) }
        let windowsAddedDuringCall = added(to: windowsBefore, in: NSApp.windows)
        let opened = TerminalController.all.filter { !existing.contains(ObjectIdentifier($0)) }
        #expect(isHandled)
        let isSettled = await settle(opened + watching)
        if !isSettled { close(opened) }
        try #require(isSettled, "the folder's window never settled")
        return FolderOpen(
            windowsBefore: windowsBefore,
            serverWindowsBefore: serverWindowsBefore,
            windowsAddedDuringCall: windowsAddedDuringCall,
            opened: opened,
            windowsAfter: NSApp.windows,
            serverWindowsAfter: ServerWindow.ownedByThisProcess()
        )
    }

    private func added(to before: [NSWindow], in after: [NSWindow]) -> [NSWindow] {
        let known = Set(before.map(ObjectIdentifier.init))
        return after.filter { !known.contains(ObjectIdentifier($0)) }
    }

    /// `window` and the windows it hangs off (as a child window or a sheet).
    private func ancestry(_ window: NSWindow) -> some Sequence<NSWindow> {
        sequence(first: window) { $0.parent ?? $0.sheetParent }
    }

    /// The palette windows of `controllers`, which each window session
    /// builds up front and keeps ordered out until ⌘O.
    private func paletteWindows(of controllers: [TerminalController]) -> Set<ObjectIdentifier> {
        guard let runtime = Self.app?.leoRuntime else { return [] }
        return Set(controllers.compactMap { $0.leoSession.flatMap { runtime.paletteWindow(for: $0.id) } }.map(ObjectIdentifier.init))
    }

    /// Of the open's windows, the shapes B-142 is about: the reported
    /// stray's size, or a window never placed or shown (at the screen
    /// origin, invisible).
    private func hasStrayShape(_ window: NSWindow) -> Bool {
        window.frame.size == Self.reportedStraySize || (!window.isVisible && window.frame.origin == .zero)
    }

    /// The AppKit windows the open added that it can't account for (see the
    /// suite's comment).
    private func strayWindows(_ open: FolderOpen) -> [NSWindow] {
        let openedWindows = Set(open.opened.compactMap(\.window).map(ObjectIdentifier.init))
        let ownPalettes = paletteWindows(of: open.opened)
        let addedDuringCall = Set(open.windowsAddedDuringCall.map(ObjectIdentifier.init))
        let foreignControllers = TerminalController.all.filter { controller in !open.opened.contains { $0 === controller } }
        let foreignWindows = Set(foreignControllers.compactMap(\.window).map(ObjectIdentifier.init))
            .union(paletteWindows(of: foreignControllers))
        func isForeign(_ window: NSWindow) -> Bool {
            ancestry(window).contains { foreignWindows.contains(ObjectIdentifier($0)) || type(of: $0) == NSWindow.self }
        }
        return added(to: open.windowsBefore, in: open.windowsAfter).filter { window in
            let id = ObjectIdentifier(window)
            if Self.isSystemTextInputCursorWindow(window) || ownPalettes.contains(id) || openedWindows.contains(id) {
                return false
            }
            if ancestry(window).contains(where: { openedWindows.contains(ObjectIdentifier($0)) }) {
                return hasStrayShape(window)
            }
            return addedDuringCall.contains(id) || !isForeign(window)
        }
    }

    /// The window-server windows the open added that AppKit doesn't list.
    private func unlistedServerWindows(_ open: FolderOpen) -> [ServerWindow] {
        let before = Set(open.serverWindowsBefore.map(\.number))
        let listed = Set(open.windowsAfter.map(\.windowNumber))
        return open.serverWindowsAfter.filter { !before.contains($0.number) && !listed.contains($0.number) }
    }

    /// Everything a failure needs to name a window and what made it.
    private func describe(_ window: NSWindow) -> String {
        let controller = window.windowController.map { String(describing: type(of: $0)) } ?? "nil"
        let content = window.contentView.map { String(describing: type(of: $0)) } ?? "nil"
        let parent = (window.parent ?? window.sheetParent).map { "#\($0.windowNumber) \(type(of: $0))" } ?? "nil"
        return "\(type(of: window)) #\(window.windowNumber) frame=\(window.frame) visible=\(window.isVisible) "
            + "level=\(window.level.rawValue) title=\"\(window.title)\" controller=\(controller) "
            + "content=\(content) parent=\(parent) bundle=\(Bundle(for: type(of: window)).bundlePath)"
    }

    private func report(_ windows: [NSWindow]) -> Comment {
        Comment(rawValue: "stray windows:\n" + windows.map(describe).joined(separator: "\n"))
    }

    private func report(_ windows: [ServerWindow]) -> Comment {
        Comment(rawValue: "server windows AppKit doesn't list:\n" + windows.map(\.description).joined(separator: "\n"))
    }

    private func makeFolder() -> LeoReservedTestDirectory {
        LeoReservedTestDirectory(template: NSTemporaryDirectory() + "leo-b142-XXXXXX")
    }

    /// The allow-list names the real system class: `TUINSWindow`, from
    /// TextInputUIMacHelper. Fails if macOS moves or renames it, which is
    /// when the allow-list needs another look.
    @Test func theAllowedTextInputCursorWindowIsTheSystemsOwn() throws {
        let framework = try #require(Bundle(path: Self.textInputCursorFramework), "no TextInputUIMacHelper")
        try framework.loadAndReturnError()
        let windowClass: AnyClass = try #require(NSClassFromString(Self.textInputCursorWindowClass))

        #expect(windowClass is NSWindow.Type)
        #expect(Bundle(for: windowClass).bundlePath == Self.textInputCursorFramework)
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

    @Test func openingAFolderAddsNoWindowAppKitDoesNotList() async throws {
        let app = try liveApp()
        let folder = makeFolder()
        defer { folder.removeIfReserved() }

        let open = try await openFolder(app, folder.reserve())
        defer { close(open.opened) }

        let unlisted = unlistedServerWindows(open)
        #expect(unlisted.isEmpty, report(unlisted))
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
        let unlisted = unlistedServerWindows(open)
        #expect(strays.isEmpty, report(strays))
        #expect(unlisted.isEmpty, report(unlisted))
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

        let open = try await openFolder(app, folder.reserve(), watching: [launch])
        defer { close(open.opened) }

        let strays = strayWindows(open)
        let unlisted = unlistedServerWindows(open)
        #expect(strays.isEmpty, report(strays))
        #expect(unlisted.isEmpty, report(unlisted))
        #expect(launch.leoWindowDidClose, "the launch window gave way to the folder's")
    }
}

/// The app has a real `Ghostty.App` to make surfaces with.
@MainActor private var hasLiveGhosttyApp: Bool {
    (NSApp.delegate as? AppDelegate)?.ghostty.app != nil
}
