import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginListInteractionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func item(
        _ id: String, subtitle: String? = nil, actions: [LeoPluginAction] = []
    ) -> LeoPluginNode.Item {
        LeoPluginNode.Item(id: id, title: "Title \(id)", subtitle: subtitle, actions: actions)
    }

    private func list(_ sections: [LeoPluginNode.Section]) -> LeoPluginNode.List {
        LeoPluginNode.List(sections: sections)
    }

    private struct Emitted: Equatable {
        let action: LeoPluginAction
        let origin: LeoPluginGesture.Origin?
    }

    /// A model wired to a recording handler. The handler captures what the
    /// renderer would send to the bridge.
    private func makeModel(_ list: LeoPluginNode.List) -> (LeoPluginListModel, Box) {
        let box = Box()
        let model = LeoPluginListModel(
            list: list,
            mint: LeoPluginGestureMint(now: { Date(timeIntervalSince1970: 1_000) }),
            handler: { action, gesture in box.emitted.append(Emitted(action: action, origin: gesture?.origin)) })
        return (model, box)
    }

    @MainActor private final class Box { var emitted: [Emitted] = [] }

    private let open = LeoPluginAction.openURL("https://example.com/a")
    private let copy = LeoPluginAction.copy("hello")
    private let cb = LeoPluginAction.callback(id: "merge-pr", payload: .int(7))

    // MARK: Actions

    @Test func contextMenuListsEveryActionOfTheItemInOrder() {
        let (model, _) = makeModel(list([.init(items: [item("a", actions: [open, copy, cb]), item("b", actions: [copy])])]))
        let entries = model.contextMenu(forItem: "a")
        #expect(entries.map(\.action) == [open, copy, cb])
        #expect(model.contextMenu(forItem: "b").map(\.action) == [copy])
        #expect(model.contextMenu(forItem: "missing").isEmpty)
    }

    @Test func returnRunsTheFirstActionWithAKeyboardGesture() {
        let (model, box) = makeModel(list([.init(items: [item("a", actions: [open, copy])])]))
        model.select(itemID: "a")
        #expect(model.handleKey(.return))
        #expect(box.emitted == [Emitted(action: open, origin: .keyboard)])
    }

    @Test func returnWithNoSelectionOrNoActionsDoesNothing() {
        let (model, box) = makeModel(list([.init(items: [item("a"), item("b", actions: [copy])])]))
        #expect(!model.handleKey(.return))
        model.select(itemID: "a")
        #expect(!model.handleKey(.return))
        #expect(box.emitted.isEmpty)
    }

    @Test func commandReturnOpensAnActionPanelListingAllActions() {
        let (model, box) = makeModel(list([.init(items: [item("a", actions: [open, copy, cb])])]))
        model.select(itemID: "a")
        #expect(model.handleKey(.commandReturn))
        #expect(model.actionPanel?.entries.map(\.action) == [open, copy, cb])
        #expect(box.emitted.isEmpty)
    }

    @Test func commandReturnWithoutActionsOpensNothing() {
        let (model, _) = makeModel(list([.init(items: [item("a")])]))
        model.select(itemID: "a")
        #expect(!model.handleKey(.commandReturn))
        #expect(model.actionPanel == nil)
    }

    @Test func choosingAPanelEntryRunsItAndClosesThePanel() {
        let (model, box) = makeModel(list([.init(items: [item("a", actions: [open, copy])])]))
        model.select(itemID: "a")
        _ = model.handleKey(.commandReturn)
        model.performPanelEntry(at: 1, origin: .click)
        #expect(box.emitted == [Emitted(action: copy, origin: .click)])
        #expect(model.actionPanel == nil)
    }

    @Test func contextMenuEntryRunsWithAClickGesture() {
        let (model, box) = makeModel(list([.init(items: [item("a", actions: [open, copy])])]))
        model.performContextMenuEntry(item: "a", at: 1)
        #expect(box.emitted == [Emitted(action: copy, origin: .click)])
    }

    @Test func entriesCarryTitlesAndSymbolsPerActionKind() {
        let send = LeoPluginAction.sendToAgent(agent: .init(machine: "m", name: "alfred"), text: "go")
        let entries = LeoPluginActionPresentation.entries(for: [cb, open, copy, send])
        #expect(entries.map(\.title) == ["Merge Pr", "Open in Browser", "Copy", "Send to alfred…"])
        #expect(entries.allSatisfy { !$0.sfSymbol.isEmpty })
    }

    // MARK: Selection and in-place updates

    @Test func rowsFlattenSectionsIntoHeadersAndItems() {
        let (model, _) = makeModel(list([
            .init(id: "s1", title: "One", items: [item("a")]),
            .init(id: "s2", title: nil, items: [item("b")]),
        ]))
        #expect(model.rows.map(\.key) == ["h:s1", "i:a", "i:b"])
    }

    @Test func selectionFollowsTheItemWhenRowsInsertAbove() {
        let (model, _) = makeModel(list([.init(items: [item("a"), item("b")])]))
        model.select(itemID: "b")
        let change = model.apply(list: list([.init(items: [item("x"), item("a"), item("b")])]))
        #expect(model.selectedItemID == "b")
        #expect(model.rowIndex(forKey: "i:b") == 2)
        #expect(change.inserted == IndexSet(integer: 0))
        #expect(change.removed.isEmpty && change.updated.isEmpty)
    }

    @Test func changingOneItemUpdatesOnlyItsRow() {
        let (model, _) = makeModel(list([.init(items: [item("a"), item("b", subtitle: "old"), item("c")])]))
        model.select(itemID: "b")
        let change = model.apply(list: list([.init(items: [item("a"), item("b", subtitle: "new"), item("c")])]))
        #expect(change.updated == IndexSet(integer: 1))
        #expect(change.inserted.isEmpty && change.removed.isEmpty)
        #expect(model.selectedItemID == "b")
    }

    @Test func deletingTheSelectedItemSelectsItsNeighbourNotNothing() {
        let (model, _) = makeModel(list([.init(items: [item("a"), item("b"), item("c")])]))
        model.select(itemID: "b")
        _ = model.apply(list: list([.init(items: [item("a"), item("c")])]))
        #expect(model.selectedItemID == "c")
        model.select(itemID: "c")
        _ = model.apply(list: list([.init(items: [item("a")])]))
        #expect(model.selectedItemID == "a")
    }

    @Test func aDiffClosesAPanelWhoseItemWasRemoved() {
        let (model, _) = makeModel(list([.init(items: [item("a", actions: [copy]), item("b", actions: [copy])])]))
        model.select(itemID: "a")
        _ = model.handleKey(.commandReturn)
        _ = model.apply(list: list([.init(items: [item("b", actions: [copy])])]))
        #expect(model.actionPanel == nil)
    }

    @Test func aPanelFollowsItsItemWhenActionsChange() {
        let (model, _) = makeModel(list([.init(items: [item("a", actions: [copy])])]))
        model.select(itemID: "a")
        _ = model.handleKey(.commandReturn)
        _ = model.apply(list: list([.init(items: [item("a", actions: [copy, open])])]))
        #expect(model.actionPanel?.entries.map(\.action) == [copy, open])
    }

    @Test func movingSelectionSkipsSectionHeaders() {
        let (model, _) = makeModel(list([
            .init(id: "s1", title: "One", items: [item("a")]),
            .init(id: "s2", title: "Two", items: [item("b")]),
        ]))
        model.moveSelection(by: 1)
        #expect(model.selectedItemID == "a")
        model.moveSelection(by: 1)
        #expect(model.selectedItemID == "b")
        model.moveSelection(by: 1)
        #expect(model.selectedItemID == "b")
        model.moveSelection(by: -5)
        #expect(model.selectedItemID == "a")
    }

    // MARK: Node dispatcher

    @Test func nodeDiffReplacesOnlyWhatChanged() {
        let a = LeoPluginNode.loading(.init(message: "x"))
        let l1 = LeoPluginNode.list(list([.init(items: [item("a")])]))
        let l2 = LeoPluginNode.list(list([.init(items: [item("a"), item("b")])]))
        // Same shape, list changed: the dispatcher must patch the list in place.
        let ops = LeoPluginTreeDiff.diff(old: [a, l1], new: [a, l2])
        #expect(ops.count == 1)
        guard case .updateList(let index, _) = ops[0] else {
            Issue.record("expected an in-place list patch, got \(ops[0])")
            return
        }
        #expect(index == 1)
    }
}
