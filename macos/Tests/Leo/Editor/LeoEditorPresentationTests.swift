import Foundation
import Testing

@testable import Ghostty

/// Which view a tab shows (B-278): Markdown and SVG render by default with
/// a Raw toggle; previews show their fetch's state.
struct LeoEditorPresentationTests {
    private let url = URL(fileURLWithPath: "/tmp/x/a.png")

    @Test func markdownDefaultsToRendered() {
        #expect(LeoEditorPresentation().content(kind: .rendered(.markdown), preview: nil, textLength: 10) == .markdown)
        #expect(LeoEditorPresentation().content(kind: .rendered(.svg), preview: nil, textLength: 10) == .svg)
    }

    @Test func rawShowsText() {
        let raw = LeoEditorPresentation().toggled()
        #expect(raw.isRaw)
        #expect(raw.content(kind: .rendered(.markdown), preview: nil, textLength: 10) == .text)
        #expect(!raw.toggled().isRaw)
    }

    @Test func aLineRevealForcesRaw() {
        #expect(LeoEditorPresentation().revealing().isRaw)
        #expect(LeoEditorPresentation().toggled().revealing().isRaw)
    }

    @Test func hugeMarkdownIsRawOnly() {
        let limit = LeoEditorPresentation.renderLimit
        #expect(LeoEditorPresentation().content(kind: .rendered(.markdown), preview: nil, textLength: limit + 1) == .text)
        #expect(!LeoEditorPresentation.canToggleRaw(kind: .rendered(.markdown), textLength: limit + 1, isPreview: false))
        #expect(LeoEditorPresentation.canToggleRaw(kind: .rendered(.markdown), textLength: limit, isPreview: false))
        #expect(!LeoEditorPresentation.canToggleRaw(kind: .text, textLength: 1, isPreview: false))
        #expect(!LeoEditorPresentation.canToggleRaw(kind: .rendered(.svg), textLength: 1, isPreview: true))
    }

    @Test func plainTextIsText() {
        #expect(LeoEditorPresentation().content(kind: .text, preview: nil, textLength: 1) == .text)
    }

    @Test(arguments: [
        (LeoFilePreviewKind.image, LeoFilePreview.State.loading(fraction: 0.5), LeoEditorPaneContent.loading(fraction: 0.5)),
        (.image, .ready(URL(fileURLWithPath: "/tmp/x/a.png")), .image(URL(fileURLWithPath: "/tmp/x/a.png"))),
        (.movie, .ready(URL(fileURLWithPath: "/tmp/x/a.png")), .movie(URL(fileURLWithPath: "/tmp/x/a.png"))),
        (.quickLook, .ready(URL(fileURLWithPath: "/tmp/x/a.png")), .quickLook(URL(fileURLWithPath: "/tmp/x/a.png"))),
        (.image, .unsupported(typeName: "PNG image"), .unavailable(typeName: "PNG image", message: nil)),
        (.text, .unsupported(typeName: "ZIP archive"), .unavailable(typeName: "ZIP archive", message: nil)),
        (.rendered(.markdown), .unsupported(typeName: "Markdown"), .unavailable(typeName: "Markdown", message: nil)),
        (.movie, .failed("gone"), .unavailable(typeName: "MPEG-4 movie", message: "gone")),
        (.movie, .closed, .empty),
    ])
    func eachPreviewStateMapsToItsView(_ kind: LeoFilePreviewKind, _ state: LeoFilePreview.State, _ expected: LeoEditorPaneContent) {
        #expect(LeoEditorPresentation().content(kind: kind, preview: state, typeName: "MPEG-4 movie", textLength: 0) == expected)
    }
}
