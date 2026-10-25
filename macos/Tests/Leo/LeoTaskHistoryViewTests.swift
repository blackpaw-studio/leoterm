import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoTaskHistoryViewTests {
    /// The daemon caps a log at a 4 MiB tail; the window must still lay out at once.
    private static let logSize = 4 * 1024 * 1024
    private static let layoutBudget = Duration.seconds(1)

    @Test func aMaximumSizeLogLaysOutAtOnce() async throws {
        var data = LeoConfigGolden.taskData()
        let line = #"{"type":"assistant","text":"checking the thing, again and again"}"# + "\n"
        data.logs["heartbeat-300.jsonl"] = String(repeating: line, count: Self.logSize / line.utf8.count)
        let fake = try LeoConfigGolden.client(tasks: data)
        let model = LeoTasksSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        model.setPage(.history)
        await model.settled()
        guard case .loaded(let log) = model.log else { Issue.record("the log did not load"); return }
        #expect(log.text.utf8.count >= Self.logSize - line.utf8.count)

        let size = NSSize(width: 700, height: 520)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let elapsed = ContinuousClock().measure {
            let host = NSHostingView(rootView: LeoTaskHistoryView(model: model).frame(width: size.width, height: size.height))
            window.contentView = host
            window.orderBack(nil)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            window.displayIfNeeded()
        }

        #expect(elapsed < Self.layoutBudget)
    }
}
