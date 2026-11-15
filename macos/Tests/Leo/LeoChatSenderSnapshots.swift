import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

private let snapshotOutputDirectory = ProcessInfo.processInfo.environment["LEO_CARD_SNAPSHOTS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

/// Renders an agent message and a `leo client` post (with its "via" caption)
/// to a PNG for a human to inspect. Only runs with `LEO_CARD_SNAPSHOTS=<output dir>`.
@MainActor @Suite(.enabled(if: snapshotOutputDirectory != nil), .timeLimit(.minutes(2)))
struct LeoChatSenderSnapshots {
    @Test func capture() async throws {
        let directory = try #require(snapshotOutputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = LeoChatPaneModel(
            clients: [.local: FakeChatClient()], recorder: FakeVoiceRecorder(),
            attachmentDirectory: FileManager.default.temporaryDirectory.appending(path: "leo-sender-snapshots-\(UUID().uuidString)")
        )
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = [
            LeoChatMessage(id: "agent", agent: "alpha", direction: .outbound, kind: .text, text: "Deploy finished. Want the logs?", ts: base),
            LeoChatMessage(
                id: "client", agent: "alpha", direction: .outbound, kind: .text, text: "Yes, post them in the channel.",
                ts: base.addingTimeInterval(60), sender: "client:laptop"
            ),
        ]
        let column = VStack(alignment: .leading, spacing: 8) {
            ForEach(messages) { LeoChatMessageRow(message: $0, position: .single, chat: model) }
        }
        .padding(12)
        .frame(width: 400, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: column)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "sender-light.png"))
    }
}
