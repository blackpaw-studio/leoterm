import AppKit
import Testing

@testable import Ghostty

/// B-440: a dragged dock tab's pasteboard.
@MainActor
struct LeoDockPaneDragTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("studio.blackpaw.leo.test.\(UUID().uuidString)"))
    }

    @Test(arguments: LeoDockPane.allCases)
    func roundTripsEachPane(pane: LeoDockPane) {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        LeoDockPaneDrag.write(pane, to: pasteboard)

        #expect(LeoDockPaneDrag.pane(from: pasteboard) == pane)
    }

    @Test func rejectsUnknownValuesAndPasteboardsWithoutTheType() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        #expect(LeoDockPaneDrag.pane(from: pasteboard) == nil)
        pasteboard.setString("browser", forType: .string)
        #expect(LeoDockPaneDrag.pane(from: pasteboard) == nil, "plain text naming a pane is not a dock drag")
        pasteboard.setString("sidebar", forType: LeoDockPaneDrag.pasteboardType)
        #expect(LeoDockPaneDrag.pane(from: pasteboard) == nil)
    }

    @Test func neverWritesTextOrFileURLs() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        LeoDockPaneDrag.write(.files, to: pasteboard)

        #expect(pasteboard.types == [LeoDockPaneDrag.pasteboardType], "the terminal takes .string and .fileURL drops")
    }
}
