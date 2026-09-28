import AppKit
import Testing

@testable import Ghostty

/// B-048: a sidebar row's double-click is decided in `rowClicked` alone,
/// from the second click (`clickCount` 2), and goes to the agent exactly
/// once: the first click already focused an open tab; otherwise the
/// second attaches (⌥: in a new window).
@MainActor struct LeoRowDoubleClickTests {
    private let worker = LeoAgentRow(host: .local, name: "worker", template: nil, status: .running, activity: .idle, actionDetail: nil)
    private let origin = LeoWindowID()

    private final class Log {
        var attaches: [AttachDisposition] = []
        var focusRequests = 0
    }

    private func makeModel(tabs: Int = 0) -> (LeoSidebarModel, Log) {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [worker], connectivity: .connected, generation: 1))
        let log = Log()
        model.attachRequested = { log.attaches.append($2) }
        model.focusExistingRequested = { _ in log.focusRequests += 1 }
        if tabs > 0 { model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [worker.id: tabs])) }
        return (model, log)
    }

    private func doubleClick(_ model: LeoSidebarModel, _ flags: NSEvent.ModifierFlags = []) {
        model.rowClicked(worker, modifierFlags: flags, clickCount: 1, from: origin)
        model.rowClicked(worker, modifierFlags: flags, clickCount: 2, from: origin)
    }

    @Test func doubleClickWithoutATabAttachesOnce() {
        let (model, log) = makeModel()

        doubleClick(model)

        #expect(log.attaches == [.reuseOrTab])
        #expect(log.focusRequests == 0)
        #expect(model.selection == worker.id)
    }

    @Test func doubleClickWithATabFocusesItOnce() {
        let (model, log) = makeModel(tabs: 1)

        doubleClick(model)

        #expect(log.focusRequests == 1)
        #expect(log.attaches.isEmpty)
    }

    @Test(arguments: [0, 1])
    func optionDoubleClickOpensOneNewWindow(tabs: Int) {
        let (model, log) = makeModel(tabs: tabs)

        doubleClick(model, .option)

        #expect(log.attaches == [.newWindow])
        #expect(log.focusRequests == 0)
    }

    @Test func aTripleClicksThirdClickOnlySelects() {
        let (model, log) = makeModel()

        doubleClick(model)
        model.rowClicked(worker, clickCount: 3, from: origin)

        #expect(log.attaches == [.reuseOrTab])
    }

    @Test func doubleClickIsInertWhileDisconnected() {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
            rows: [worker], connectivity: .disconnected(reason: "gone", isRetrying: false), generation: 1))
        var attaches = 0
        model.attachRequested = { _, _, _ in attaches += 1 }

        doubleClick(model)

        #expect(attaches == 0)
    }
}
