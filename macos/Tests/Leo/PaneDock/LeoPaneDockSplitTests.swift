import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-439 in a real window: Browser and Files dock right (the split's
/// trailing items) or below the terminal (over the agent drawer), each dock
/// with its own divider, remembered size and 200 pt stop.
@MainActor
struct LeoPaneDockSplitTests {
    private static let browserKey = LeoAgentBrowserKey(host: .local, agent: "alpha")
    /// `setPosition` lands dividers on whole points; a measured edge can be
    /// a rounding step off.
    private static let pointTolerance: CGFloat = 1

    private let presence = FakePresence()
    private let defaults = LeoInMemoryDefaults()

    // MARK: Both edges at once

    @Test func browserBelowAndFilesRightAreBothVisible() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            store.setEdge(.below, for: .browser)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }

            try await harness.openFile(in: sandbox)
            presence.open(Self.browserKey)
            await harness.settle()

            #expect(harness.rightStripItem.isCollapsed == false)
            #expect(harness.strip(harness.dock.filesStrip)?.shown != nil, "the file shows on the right")
            #expect(harness.strip(harness.dock.filesStrip)?.shownBrowser == nil)
            #expect(harness.terminalDock.bottomItem.isCollapsed == false)
            #expect(harness.strip(harness.dock.browserStrip)?.shownBrowser != nil, "the page shows below")
            let terminal = harness.frame(of: harness.terminalView)
            let bottom = harness.frame(of: harness.terminalDock.bottom.view)
            #expect(bottom.height >= LeoPaneDockMetrics.minimumSize)
            #expect(bottom.maxY <= terminal.minY + Self.pointTolerance, "under the terminal")
            #expect(harness.frame(of: harness.rightStripView).minX >= terminal.maxX, "beside it")
        }
    }

    /// The drawer keeps the terminal column's width and its own height, under the bottom dock.
    @Test func theAgentDrawerStaysUnderTheTerminalColumn() async throws {
        let store = LeoPaneDockStore(defaults: defaults)
        store.setEdge(.below, for: .browser)
        let harness = LeoPaneDockTestHarness(presence: presence, store: store, agentPane: true)
        defer { harness.close() }
        await harness.settle()
        let drawerBefore = harness.frame(of: try #require(harness.drawerView))
        try #require(drawerBefore.height > 0)

        presence.open(Self.browserKey)
        await harness.settle()

        let drawer = harness.frame(of: try #require(harness.drawerView))
        let column = harness.frame(of: harness.terminalDock.view)
        let bottom = harness.frame(of: harness.terminalDock.bottom.view)
        #expect(harness.terminalDock.bottomItem.isCollapsed == false)
        #expect(abs(drawer.minX - column.minX) <= Self.pointTolerance && abs(drawer.maxX - column.maxX) <= Self.pointTolerance)
        #expect(abs(bottom.minX - column.minX) <= Self.pointTolerance && abs(bottom.maxX - column.maxX) <= Self.pointTolerance)
        #expect(drawer.maxY <= bottom.minY + Self.pointTolerance, "the drawer is below the bottom dock")
        #expect(abs(drawer.height - drawerBefore.height) <= Self.pointTolerance)
    }

    // MARK: Dividers

    @Test func draggingEitherDockDividerStopsAtTwoHundredPoints() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            store.setEdge(.below, for: .browser)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }
            try await harness.openFile(in: sandbox)
            presence.open(Self.browserKey)
            await harness.settle()

            harness.dragRightDock(toWidth: 40)
            harness.dragBottomDock(toHeight: 40)
            await harness.settle()

            #expect(harness.rightStripItem.isCollapsed == false)
            #expect(abs(harness.rightStripWidth - LeoPaneDockMetrics.minimumSize) <= Self.pointTolerance)
            #expect(harness.terminalDock.bottomItem.isCollapsed == false)
            #expect(abs(harness.terminalDock.bottomHeight - LeoPaneDockMetrics.minimumSize) <= Self.pointTolerance)
        }
    }

    /// Files on the right with no file open is its outline alone: the dock
    /// still stops at 200 pt, not at the outline's own 180.
    @Test func theRightDockStopsAtTwoHundredPointsWithOnlyTheOutline() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = LeoPaneDockTestHarness(presence: presence, store: LeoPaneDockStore(defaults: defaults))
            defer { harness.close() }
            await harness.pane.browser.open(LeoEditorAgentContext(host: .local, name: "alpha", workspace: sandbox.root))
            await harness.settle()
            let outline = try #require(harness.rightOutlineItem)
            try #require(outline.isCollapsed == false)
            try #require(harness.rightStripItem.isCollapsed)

            harness.dragRightDock(toWidth: 40)
            await harness.settle()

            #expect(outline.isCollapsed == false)
            #expect(abs(harness.rightOutlineWidth - LeoPaneDockMetrics.minimumSize) <= Self.pointTolerance)
        }
    }

    @Test func draggingADockDividerRemembersItsSize() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            store.setEdge(.below, for: .browser)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }
            try await harness.openFile(in: sandbox)
            presence.open(Self.browserKey)
            await harness.settle()

            harness.dragRightDock(toWidth: 380)
            harness.dragBottomDock(toHeight: 240)
            await harness.settle()

            #expect(abs((store.size(of: .right) ?? 0) - 380) <= Self.pointTolerance)
            #expect(abs((store.size(of: .below) ?? 0) - 240) <= Self.pointTolerance)
        }
    }

    @Test func aWindowResizeRemembersNoSize() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            store.setEdge(.below, for: .browser)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }
            try await harness.openFile(in: sandbox)
            presence.open(Self.browserKey)
            await harness.settle()

            harness.window.setContentSize(NSSize(width: 1_000, height: 500))
            await harness.settle()

            #expect(store.size(of: .right) == nil)
            #expect(store.size(of: .below) == nil)
        }
    }

    @Test func aDockOpensAtItsRememberedSize() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            store.setEdge(.below, for: .browser)
            store.setSize(420, of: .right)
            store.setSize(260, of: .below)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }

            try await harness.openFile(in: sandbox)
            presence.open(Self.browserKey)
            await harness.settle()

            #expect(abs(harness.rightStripWidth - 420) <= Self.pointTolerance)
            #expect(abs(harness.terminalDock.bottomHeight - 260) <= Self.pointTolerance)
        }
    }

    /// After a relaunch the window is built with its panes already open:
    /// the docks open from the saved layout, with no move or drag after.
    @Test func aWindowBuiltWithPanesOpenDocksThemWhereTheStoreSays() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let saved = LeoPaneDockStore(defaults: defaults)
            saved.setEdge(.below, for: .browser)
            saved.setEdge(.right, for: .files)
            saved.setSize(260, of: .below)
            let panes = LeoPaneDockTestHarness.makePanes(presence: presence)
            try await panes.active.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
            let source = presence.open(Self.browserKey)
            let page = NSView()
            source.activeView = page
            source.viewHost.adopt(page)
            await drainMainQueue()

            let harness = LeoPaneDockTestHarness(
                presence: presence, store: LeoPaneDockStore(defaults: defaults), agentPane: true, panes: panes)
            defer { harness.close() }
            await harness.settle()

            #expect(harness.terminalDock.bottomItem.isCollapsed == false)
            #expect(page.isDescendant(of: harness.terminalDock.bottom.view), "the page is below")
            #expect(harness.dock.rightStrip?.hosted === harness.dock.filesStrip)
            #expect(harness.rightStripItem.isCollapsed == false)
            #expect(harness.strip(harness.dock.filesStrip)?.shown != nil, "the file is on the right")
            #expect(harness.rightStripWidth >= LeoPaneDockMetrics.minimumSize - Self.pointTolerance)
            #expect(abs(harness.terminalDock.bottomHeight - 260) <= Self.pointTolerance)
            let drawer = harness.frame(of: try #require(harness.drawerView))
            let column = harness.frame(of: harness.terminalDock.view)
            #expect(drawer.height > 0)
            #expect(abs(drawer.minX - column.minX) <= Self.pointTolerance && abs(drawer.maxX - column.maxX) <= Self.pointTolerance)
            #expect(drawer.maxY <= harness.frame(of: harness.terminalDock.bottom.view).minY + Self.pointTolerance, "the drawer is below the dock")
        }
    }

    // MARK: Closing and moving

    @Test func closingADockedPaneGivesItsSpaceBackToTheTerminal() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            store.setEdge(.below, for: .browser)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }
            try await harness.openFile(in: sandbox)
            presence.open(Self.browserKey)
            await harness.settle()
            try #require(harness.terminalView.frame.height < harness.terminalDock.view.frame.height - 100)

            harness.pane.closeAgentBrowser()
            await harness.settle()
            #expect(harness.terminalDock.bottomItem.isCollapsed)
            #expect(abs(harness.terminalView.frame.height - harness.terminalDock.view.frame.height) <= Self.pointTolerance)

            _ = await harness.pane.tabs.closeAll()
            await harness.settle()
            #expect(harness.rightStripItem.isCollapsed)
            #expect(abs(harness.terminalDock.view.frame.width - harness.split.splitView.bounds.width) <= Self.pointTolerance)
        }
    }

    @Test func movingTheBrowserKeepsTheSameWebView() async throws {
        let store = LeoPaneDockStore(defaults: defaults)
        let harness = LeoPaneDockTestHarness(presence: presence, store: store)
        defer { harness.close() }
        let source = presence.open(Self.browserKey)
        let page = NSView()
        source.activeView = page
        source.viewHost.adopt(page)
        source.changed()
        await harness.settle()
        let rightSlot = try #require(harness.strip(harness.dock.filesStrip)?.shownBrowser?.pageSlot)
        try #require(page.superview === rightSlot)

        harness.dock.move(.browser, to: .below)
        await harness.settle()

        let belowSlot = try #require(harness.strip(harness.dock.browserStrip)?.shownBrowser?.pageSlot)
        #expect(page.superview === belowSlot, "the same page, now below")
        #expect(page.window === harness.window)
        #expect(!source.calls.contains("reload"))
        #expect(harness.rightStripItem.isCollapsed, "nothing left on the right")
    }

    /// One store for every window: a move in one window moves the pane in all.
    @Test func aMoveReachesEveryWindow() async {
        let store = LeoPaneDockStore(defaults: defaults)
        let first = LeoPaneDockTestHarness(presence: presence, store: store)
        let second = LeoPaneDockTestHarness(presence: presence, store: store)
        defer {
            first.close()
            second.close()
        }
        presence.open(Self.browserKey)
        await first.settle()
        await second.settle()

        first.dock.move(.browser, to: .below)
        await first.settle()
        await second.settle()

        #expect(second.terminalDock.bottomItem.isCollapsed == false)
        #expect(second.strip(second.dock.browserStrip)?.shownBrowser != nil)
    }

    @Test func theBrowserTabMenuOffersBothEdgesWithTheCurrentOneChecked() async throws {
        let store = LeoPaneDockStore(defaults: defaults)
        let harness = LeoPaneDockTestHarness(presence: presence, store: store)
        defer { harness.close() }
        presence.open(Self.browserKey)
        await harness.settle()
        let tabBar = try #require(harness.strip(harness.dock.filesStrip)?.tabBar)
        let button = try #require(tabBar.buttons.first)
        try #require(tabBar.items.first?.isBrowser == true)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        let menu = try #require(button.menu(for: click))

        #expect(menu.items.map(\.title) == ["Dock Right", "Dock Below"])
        #expect(menu.items.map(\.state) == [.on, .off])
        let below = try #require(menu.items.last)
        _ = (below.target as? NSObject)?.perform(below.action, with: below)
        await harness.settle()
        #expect(store.layout.edge(of: .browser) == .below)
        #expect(store.layout.edge(of: .files) == .right)
        #expect(harness.terminalDock.bottomItem.isCollapsed == false)
    }

    /// A file's tab moves Files: its tabs and its outline go below together.
    @Test func aFileTabMenuMovesFilesWithItsOutline() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let store = LeoPaneDockStore(defaults: defaults)
            let harness = LeoPaneDockTestHarness(presence: presence, store: store)
            defer { harness.close() }
            try await harness.pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
            try await harness.pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("b.swift", "let b = 2")))
            await harness.settle()
            let tabBar = try #require(harness.strip(harness.dock.filesStrip)?.tabBar)
            try #require(tabBar.items.count == 2)

            let menu = try #require(tabBar.dockMenu(forItemAt: 1))
            #expect(menu.items.map(\.state) == [.on, .off])
            let below = try #require(menu.items.last)
            _ = (below.target as? NSObject)?.perform(below.action, with: below)
            await harness.settle()

            #expect(store.layout.edge(of: .files) == .below)
            #expect(harness.dock.belowStrip?.hosted === harness.dock.filesStrip)
            #expect(harness.dock.belowOutline?.hosted === harness.dock.outline)
            #expect(harness.rightStripItem.isCollapsed)
            #expect(harness.terminalDock.bottomItem.isCollapsed == false)
            #expect(harness.strip(harness.dock.filesStrip)?.shown?.view.window === harness.window, "the same tab views, now below")
        }
    }
}
