import AppKit
import Combine
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Settings pane host at view level: a reconnect to the same machine must
/// keep the mounted pane, with its view-owned state, instead of rebuilding it.
@MainActor
struct LeoSettingsPaneStateTests {
    private final class StatusBox {
        var statuses: [LeoHostID: LeoMachineStatus] = [.local: .connected]
    }

    private struct Harness {
        let target: LeoSettingsTargetModel
        let clients: FakeMachineClients
        let subject: PassthroughSubject<[LeoHostID: LeoMachineStatus], Never>
        let box: StatusBox

        /// A tunnel blip, with the view given a turn at each stage: gone, then back on a new client.
        @MainActor func blip(to config: LeoFakeConfigClient, observing stage: (String) async -> Void) async {
            clients.disconnect(.local)
            box.statuses[.local] = .failed("tunnel dropped")
            subject.send(box.statuses)
            await target.settled()
            await stage("disconnected")
            clients.connect(.local, ConfigStubDaemon(config: config))
            box.statuses[.local] = .connected
            subject.send(box.statuses)
            await target.settled()
            await stage("reconnected")
        }
    }

    private static func harness(config: LeoFakeConfigClient) -> Harness {
        let box = StatusBox()
        let subject = PassthroughSubject<[LeoHostID: LeoMachineStatus], Never>()
        let clients = FakeMachineClients(daemons: [.local: ConfigStubDaemon(config: config)])
        let target = LeoSettingsTargetModel(
            clients: clients, machines: { [.local] }, status: { box.statuses[$0] }, statuses: subject.eraseToAnyPublisher(),
            reconnect: { _ in }, initialHost: nil
        )
        return Harness(target: target, clients: clients, subject: subject, box: box)
    }

    /// Mounts `view` in an offscreen window and lets SwiftUI settle.
    private static func host(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 820, height: 700), styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        return window
    }

    private static func pump() async {
        for _ in 0..<6 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            await Task.yield()
        }
    }

    /// State a pane keeps in the view, counted when it is created.
    private final class Probe: ObservableObject {
        static var created = 0
        init() { Self.created += 1 }
    }

    private struct ProbeContent: View {
        @StateObject private var probe = Probe()
        var body: some View { Text("pane \(ObjectIdentifier(probe).hashValue)") }
    }

    @MainActor private final class DirtyPane: LeoSettingsPane {
        var hasUnsavedChanges = true
        func discardChanges() { hasUnsavedChanges = false }
        func reload(using client: any LeoConfigClient) async {}
    }

    @Test func aViewOwnedStateObjectSurvivesAReconnectOfADirtyPane() async throws {
        let tab = LeoSettingsTab.config("templates")
        let harness = Self.harness(config: try LeoConfigGolden.client())
        let pane = DirtyPane()
        harness.target.register(pane, for: tab)
        await harness.target.settled()
        Probe.created = 0
        let window = Self.host(LeoSettingsPaneState(target: harness.target, tab: tab) { _ in ProbeContent() })
        defer { window.close() }
        await Self.pump()
        #expect(Probe.created == 1)

        await harness.blip(to: try LeoConfigGolden.client()) { _ in await Self.pump() }

        #expect(Probe.created == 1)
        #expect(pane.hasUnsavedChanges)
    }

    @Test func theTemplatesPaneKeepsItsEditedDraftThroughAReconnect() async throws {
        let harness = Self.harness(config: try LeoConfigGolden.client())
        let window = Self.host(LeoTemplatesSettingsView(target: harness.target))
        defer { window.close() }
        await harness.target.settled()
        let tab = LeoTemplatesSettingsView.tab
        await awaitCondition { @MainActor in
            await Self.pump()
            return (harness.target.pane(for: tab) as? LeoConfigCollectionModel)?.phase == .loaded
        }
        let before = try #require(harness.target.pane(for: tab) as? LeoConfigCollectionModel)
        before.set("model", .string("sonnet"))

        await harness.blip(to: try LeoConfigGolden.client()) { _ in await Self.pump() }
        await Self.pump()

        let after = try #require(harness.target.pane(for: tab) as? LeoConfigCollectionModel)
        #expect(after === before)
        #expect(after.draft?.value(at: "model") == .string("sonnet"))
        #expect(after.hasUnsavedChanges)
        #expect(after.phase == .loaded)
    }
}
