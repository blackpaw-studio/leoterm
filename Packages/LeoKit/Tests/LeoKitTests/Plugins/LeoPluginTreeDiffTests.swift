import Testing

@testable import LeoKit

struct LeoPluginTreeDiffTests {
    private func item(_ id: String, _ title: String = "t") -> LeoPluginNode.Item {
        .init(id: id, title: title)
    }

    private func list(_ ids: [String], title: String = "t") -> [LeoPluginNode] {
        [.list(.init(sections: [.init(id: "s", title: nil, items: ids.map { item($0, title) })]))]
    }

    private func patchEdits(_ ops: [LeoPluginTreeOp]) -> [LeoPluginItemEdit]? {
        guard case .updateList(_, let patch) = ops.first else { return nil }
        return patch.sections.first?.itemEdits
    }

    @Test func identicalTreesProduceNoOps() {
        #expect(LeoPluginTreeDiff.diff(old: list(["a", "b"]), new: list(["a", "b"])).isEmpty)
    }

    @Test func insertIsKeyed() {
        let ops = LeoPluginTreeDiff.diff(old: list(["a", "c"]), new: list(["a", "b", "c"]))
        #expect(patchEdits(ops) == [.insert(id: "b", index: 1, item: item("b"))])
    }

    @Test func deleteIsKeyed() {
        let ops = LeoPluginTreeDiff.diff(old: list(["a", "b", "c"]), new: list(["a", "c"]))
        #expect(patchEdits(ops) == [.delete(id: "b")])
    }

    @Test func moveKeepsIdentity() {
        let ops = LeoPluginTreeDiff.diff(old: list(["a", "b", "c"]), new: list(["c", "a", "b"]))
        #expect(patchEdits(ops) == [.move(id: "c", index: 0)])
    }

    @Test func updateInPlace() {
        let ops = LeoPluginTreeDiff.diff(old: list(["a"], title: "x"), new: list(["a"], title: "y"))
        #expect(patchEdits(ops) == [.update(id: "a", item: item("a", "y"))])
    }

    @Test func typeChangeReplacesWholeTree() {
        let new: [LeoPluginNode] = [.loading(.init(message: nil))]
        #expect(LeoPluginTreeDiff.diff(old: list(["a"]), new: new) == [.replaceRoot(new)])
    }

    @Test func rootCountChangeReplacesWholeTree() {
        let new = list(["a"]) + [LeoPluginNode.loading(.init(message: nil))]
        #expect(LeoPluginTreeDiff.diff(old: list(["a"]), new: new) == [.replaceRoot(new)])
    }

    @Test func nonListSameTypeReplacesThatNode() {
        let old: [LeoPluginNode] = [.detail(.init(markdown: "a"))]
        let new: [LeoPluginNode] = [.detail(.init(markdown: "b"))]
        #expect(LeoPluginTreeDiff.diff(old: old, new: new) == [.replaceNode(index: 0, node: new[0])])
    }

    @Test func applyingEditsReproducesNewItems() {
        let old = ["a", "b", "c", "d"].map { item($0) }
        let new = [item("d"), item("x"), item("a", "changed"), item("c")]
        let edits = LeoPluginTreeDiff.itemEdits(old: old, new: new)
        #expect(LeoPluginTreeDiff.apply(edits, to: old) == new)
    }

    @Test func applyingListPatchReproducesNewList() {
        let mk = { (secs: [(String?, String?, [String])]) in
            LeoPluginNode.List(sections: secs.map { .init(id: $0.0, title: $0.1, items: $0.2.map { item($0) }) })
        }
        let old = mk([("a", "A", ["1", "2"]), (nil, nil, ["3"]), ("b", "B", ["4"])])
        let new = mk([("b", "B2", ["4", "5"]), ("a", "A", ["2"]), ("z", nil, ["6"])])
        guard case .updateList(_, let patch) = LeoPluginTreeDiff.diff(old: [.list(old)], new: [.list(new)])[0] else {
            Issue.record("expected updateList"); return
        }
        #expect(LeoPluginTreeDiff.apply(patch, to: old) == new)
    }

    @Test func sectionStructureAndTitleChangesAreKeyed() {
        let old: [LeoPluginNode] = [.list(.init(sections: [
            .init(id: "a", title: "A", items: [item("1")]),
            .init(id: "b", title: "B", items: [item("2")]),
        ]))]
        let new: [LeoPluginNode] = [.list(.init(sections: [
            .init(id: "a", title: "A2", items: [item("1")]),
            .init(id: "c", title: "C", items: []),
        ]))]
        guard case .updateList(_, let patch) = LeoPluginTreeDiff.diff(old: old, new: new)[0] else {
            Issue.record("expected updateList"); return
        }
        #expect(patch.sectionEdits.contains(.delete(key: "b")))
        #expect(patch.sectionEdits.contains(.insert(key: "c", index: 1, section: new.listSections[1])))
        #expect(patch.sections.contains { $0.key == "a" && $0.title == "A2" && $0.retitled })
    }
}

extension [LeoPluginNode] {
    fileprivate var listSections: [LeoPluginNode.Section] {
        guard case .list(let l) = self[0] else { return [] }
        return l.sections
    }
}
