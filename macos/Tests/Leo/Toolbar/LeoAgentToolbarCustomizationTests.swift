import AppKit
import Combine
import Testing

@testable import Ghostty

@MainActor
struct LeoAgentToolbarCustomizationTests {
    private func install(_ defaults: UserDefaults, hidesItemsInPlace: Bool? = nil) -> (window: NSWindow, toolbar: LeoAgentToolbar) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let toolbar = LeoAgentToolbar(layoutStore: LeoToolbarLayoutStore(defaults: defaults))
        if let hidesItemsInPlace { toolbar.hidesItemsInPlace = hidesItemsInPlace }
        toolbar.install(on: window)
        return (window, toolbar)
    }

    @Test func aSavedArrangementBuildsTheToolbar() {
        let defaults = LeoInMemoryDefaults()
        LeoToolbarLayoutStore(defaults: defaults).save([
            .leoTitleMenu, .flexibleSpace, .leoActivity, .flexibleSpace, .leoAgentPane, .leoViewSwitch, .leoMore,
        ])
        let (window, _) = install(defaults)
        defer { window.close() }

        let ids = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(!ids.contains(.leoFiles) && !ids.contains(.leoBrowser) && !ids.contains(.leoInterrupt), "\(ids.map(\.rawValue))")
        #expect(ids.contains(.leoAgentPane) && ids.contains(.leoViewSwitch) && ids.contains(.leoMore))
    }

    @Test func theWindowsOwnTitleReturnsWhileTheToolbarIsHidden() {
        let (window, toolbar) = install(LeoInMemoryDefaults())
        defer { window.close() }

        #expect(window.titleVisibility == .hidden)
        window.toolbar?.isVisible = false
        toolbar.syncTitleVisibility()
        #expect(window.titleVisibility == .visible)
        window.toolbar?.isVisible = true
        toolbar.syncTitleVisibility()
        #expect(window.titleVisibility == .hidden)
    }

    @Test func noPopoverAnchorIsOfferedWhileTheToolbarIsHidden() {
        let (window, toolbar) = install(LeoInMemoryDefaults())
        defer { window.close() }

        window.toolbar?.isVisible = false
        #expect(toolbar.titleAnchorView == nil)
    }

    @Test func theDefaultSetStaysTheShippedOneWhileTheSavedLayoutIsTheLiveToolbar() throws {
        let defaults = LeoInMemoryDefaults()
        LeoToolbarLayoutStore(defaults: defaults).save([
            .leoTitleMenu, .flexibleSpace, .leoActivity, .flexibleSpace, .leoAgentPane, .leoViewSwitch, .leoMore,
        ])
        let (window, toolbar) = install(defaults, hidesItemsInPlace: true)
        defer { window.close() }
        let nsToolbar = try #require(window.toolbar)

        // The palette's "drag the default set" row reads this: it must restore the shipped layout.
        let defaultSet = toolbar.toolbarDefaultItemIdentifiers(nsToolbar)
        #expect(defaultSet.contains(.leoFiles) && defaultSet.contains(.leoInterrupt), "\(defaultSet.map(\.rawValue))")
        let live = nsToolbar.items.map(\.itemIdentifier)
        #expect(!live.contains(.leoFiles) && !live.contains(.leoInterrupt), "\(live.map(\.rawValue))")
    }

    @Test func theToolbarIsCustomizableButNeverAutosavesItself() {
        let (window, _) = install(LeoInMemoryDefaults())
        defer { window.close() }

        #expect(window.toolbar?.allowsUserCustomization == true)
        #expect(window.toolbar?.autosavesConfiguration == false)
    }

    @Test func theTitleSwitchAndMoreCannotBeDraggedOutAndNothingLandsBeforeTheTitle() throws {
        let (window, toolbar) = install(LeoInMemoryDefaults())
        defer { window.close() }
        let nsToolbar = try #require(window.toolbar)

        #expect(toolbar.toolbarImmovableItemIdentifiers(nsToolbar).isSuperset(of: [.leoTitleMenu, .leoViewSwitch, .leoMore]))
        #expect(!toolbar.toolbar(nsToolbar, itemIdentifier: .leoFiles, canBeInsertedAt: 0))
        #expect(toolbar.toolbar(nsToolbar, itemIdentifier: .leoFiles, canBeInsertedAt: nsToolbar.items.count))
    }

    @Test func theAppsOwnItemChangesDoNotFreezeTheDefaultLayoutAsTheUsers() async {
        let defaults = LeoInMemoryDefaults()
        let (window, toolbar) = install(defaults)
        defer { window.close() }
        let updateVisible = PassthroughSubject<Bool, Never>()
        toolbar.bind(updateVisible: updateVisible)

        updateVisible.send(true)
        updateVisible.send(false)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(defaults.object(forKey: LeoToolbarLayoutStore.key) == nil)
    }
}
