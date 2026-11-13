import AppKit
import Testing

@testable import Ghostty

struct LeoToolbarLayoutStoreTests {
    typealias Identifier = NSToolbarItem.Identifier

    private func makeStore(_ defaults: UserDefaults = LeoInMemoryDefaults()) -> LeoToolbarLayoutStore {
        LeoToolbarLayoutStore(defaults: defaults)
    }

    @Test func withNothingSavedTheDefaultOrderComesBack() {
        #expect(makeStore().restoredOrder() == LeoAgentToolbarItems.defaultOrder)
    }

    @Test func aSavedLayoutRoundTripsWithTheAppManagedItemsPutBack() {
        let store = makeStore()
        let custom: [Identifier] = [
            .leoTitleMenu, .flexibleSpace, .leoActivity, .flexibleSpace, .leoAgentPane, .leoInterrupt, .leoViewSwitch, .leoMore,
        ]
        store.save(custom)

        let restored = store.restoredOrder()
        // What the user arranged keeps its order; Files and Browser (removed) stay gone.
        #expect(restored.filter { custom.contains($0) } == custom)
        #expect(!restored.contains(.leoFiles) && !restored.contains(.leoBrowser))
        // The app-managed items are back, each ahead of the item that follows it by default.
        #expect(restored.contains(.leoSidebarToggle) && restored.contains(.leoSplitSeparator))
        #expect(restored.contains(.leoUpdate) && restored.contains(.leoResetZoom))
        #expect(restored.first == .leoSidebarToggle)
    }

    @Test func savingLeavesTheAppManagedItemsOutOfTheStoredList() {
        let defaults = LeoInMemoryDefaults()
        makeStore(defaults).save(LeoAgentToolbarItems.defaultOrder)

        let stored = defaults.stringArray(forKey: LeoToolbarLayoutStore.key) ?? []
        for managed in LeoAgentToolbarItems.appManaged {
            #expect(!stored.contains(managed.rawValue), "\(managed.rawValue) was stored")
        }
        #expect(stored.contains(Identifier.leoFiles.rawValue))
    }

    @Test func unknownAndRepeatedIdentifiersAreDropped() {
        let defaults = LeoInMemoryDefaults()
        defaults.set(
            ["leo.toolbar.gone", Identifier.leoFiles.rawValue, Identifier.leoFiles.rawValue, Identifier.leoMore.rawValue],
            forKey: LeoToolbarLayoutStore.key)

        let restored = makeStore(defaults).restoredOrder()

        #expect(!restored.contains(Identifier("leo.toolbar.gone")))
        #expect(restored.filter { $0 == .leoFiles }.count == 1)
    }

    @Test func aMissingImmovableItemIsRestoredAheadOfItsDefaultSuccessor() {
        let defaults = LeoInMemoryDefaults()
        // The switch is missing: it belongs after Agent Pane and before Interrupt.
        defaults.set(
            [Identifier.leoTitleMenu, .leoActivity, .leoFiles, .leoAgentPane, .leoInterrupt, .leoMore].map(\.rawValue),
            forKey: LeoToolbarLayoutStore.key)

        let restored = makeStore(defaults).restoredOrder()

        let switchIndex = try? #require(restored.firstIndex(of: .leoViewSwitch))
        #expect(switchIndex == restored.firstIndex(of: .leoInterrupt).map { $0 - 1 })
    }

    @Test func anInjectedStoreNeverTouchesTheStandardDefaults() {
        let key = LeoToolbarLayoutStore.key
        let before = UserDefaults.standard.object(forKey: key) as? [String]

        makeStore().save([.leoTitleMenu, .leoMore])

        #expect(UserDefaults.standard.object(forKey: key) as? [String] == before)
    }
}
