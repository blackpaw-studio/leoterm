import AppKit
import Foundation
import Testing

@testable import Ghostty

struct LeoImagePasteTests {
    private struct Row: CustomTestStringConvertible {
        let key: LeoImagePaste.Key
        let hasImage: Bool
        let hasText: Bool
        let expectedOnRemoteAgent: LeoImagePaste.Decision
        var testDescription: String { "\(key) image=\(hasImage) text=\(hasText)" }
    }

    private static let rows: [Row] = [
        Row(key: .controlV, hasImage: true, hasText: false, expectedOnRemoteAgent: .uploadImage),
        Row(key: .controlV, hasImage: true, hasText: true, expectedOnRemoteAgent: .uploadImage),
        Row(key: .controlV, hasImage: false, hasText: true, expectedOnRemoteAgent: .passThrough),
        Row(key: .controlV, hasImage: false, hasText: false, expectedOnRemoteAgent: .passThrough),
        Row(key: .commandV, hasImage: true, hasText: false, expectedOnRemoteAgent: .uploadImage),
        Row(key: .commandV, hasImage: true, hasText: true, expectedOnRemoteAgent: .passThrough),
        Row(key: .commandV, hasImage: false, hasText: true, expectedOnRemoteAgent: .passThrough),
        Row(key: .commandV, hasImage: false, hasText: false, expectedOnRemoteAgent: .passThrough),
    ]

    /// The spec's table on a remote agent; every other surface keeps today's
    /// behaviour whatever is on the clipboard.
    @Test(arguments: rows, LeoImagePaste.SurfaceKind.allCases)
    private func decisionTable(row: Row, surface: LeoImagePaste.SurfaceKind) {
        let decision = LeoImagePaste.decide(key: row.key, hasImage: row.hasImage, hasText: row.hasText, surface: surface)
        #expect(decision == (surface == .remoteAgent ? row.expectedOnRemoteAgent : .passThrough))
    }
}
