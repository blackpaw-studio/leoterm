import Combine
import Testing

@testable import Ghostty

/// B-439: where each pane docks, and each dock's size, are app-wide and
/// outlive the app.
@MainActor
struct LeoPaneDockStoreTests {
    @Test func dockPositionSurvivesARelaunch() {
        let defaults = LeoInMemoryDefaults()
        LeoPaneDockStore(defaults: defaults).setEdge(.below, for: .browser)

        let relaunched = LeoPaneDockStore(defaults: defaults)

        #expect(relaunched.layout.edge(of: .browser) == .below)
        #expect(relaunched.layout.edge(of: .files) == .right)
    }

    @Test func eachDockRemembersItsOwnSize() {
        let defaults = LeoInMemoryDefaults()
        let store = LeoPaneDockStore(defaults: defaults)
        #expect(store.size(of: .right) == nil)
        #expect(store.size(of: .below) == nil)

        store.setSize(420, of: .right)
        store.setSize(260, of: .below)

        let relaunched = LeoPaneDockStore(defaults: defaults)
        #expect(relaunched.size(of: .right) == 420)
        #expect(relaunched.size(of: .below) == 260)
    }

    @Test func aCorruptStoredEdgeFallsBackToRight() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("left", forKey: LeoPaneDockStore.Keys.edge(of: .browser))
        defaults.set(3, forKey: LeoPaneDockStore.Keys.edge(of: .files))
        defaults.set("wide", forKey: LeoPaneDockStore.Keys.size(of: .right))

        let store = LeoPaneDockStore(defaults: defaults)

        #expect(store.layout == LeoPaneDockLayout())
        #expect(store.size(of: .right) == nil)
    }

    /// Every window hears a move once the store has it: what they read back
    /// is the new layout.
    @Test func aMoveReachesSubscribersAfterItIsStored() {
        let store = LeoPaneDockStore(defaults: LeoInMemoryDefaults())
        var heard: [LeoPaneDockLayout] = []
        let subscription = store.changes.sink { _ in heard.append(store.layout) }
        defer { subscription.cancel() }

        store.setEdge(.below, for: .files)
        store.setEdge(.below, for: .files)

        #expect(heard == [LeoPaneDockLayout().moving(.files, to: .below)])
    }
}
