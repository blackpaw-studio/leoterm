import AppKit
import Testing

@testable import Ghostty

/// Where the pane's rows land in a real window (B-045): a close waiting on
/// a save shows its banner as its own leading-aligned row under the
/// header, which stays in place with its file name and close button.
@MainActor
struct LeoEditorPaneLayoutTests {
    @Test(.timeLimit(.minutes(1)))
    func theHeaderStaysAndTheClosingBannerIsALeadingRowBelowIt() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = pane.view
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            model.confirmUnsaved = { _ in .save }
            access.hangsWrites = true

            let closing = Task { await model.close() }
            await access.waitUntilWriting()
            #expect(await eventually { pane.banner.banner?.message.hasPrefix("Closing") == true })
            pane.view.layoutSubtreeIfNeeded()

            let width = pane.view.bounds.width
            let header = try #require(pane.view.subviews.first { $0 is LeoEditorHeaderView })
            let headerFrame = frame(of: header, in: pane.view)
            let bannerFrame = frame(of: pane.banner, in: pane.view)
            #expect(!header.isHidden)
            #expect(headerFrame.minX == 0 && headerFrame.width == width, "the header spans the pane: \(headerFrame)")
            #expect(headerFrame.maxY == pane.view.bounds.maxY, "the header stays on top: \(headerFrame)")
            #expect(bannerFrame.minX == 0 && bannerFrame.width == width, "the banner is its own full-width row: \(bannerFrame)")
            #expect(bannerFrame.maxY <= headerFrame.minY, "the banner sits below the header")
            let icon = try #require(firstDescendant(of: pane.banner, NSImageView.self))
            #expect(frame(of: icon, in: pane.banner).minX <= 12, "leading-aligned: \(frame(of: icon, in: pane.banner))")
            let recents = try #require(firstDescendant(of: header, NSPopUpButton.self))
            #expect(frame(of: recents, in: header).minX <= 8 && recents.frame.width > 0, "the file name is still shown")

            access.release()
            #expect(await closing.value)
            window.contentView = nil
        }
    }

    private func frame(of view: NSView, in root: NSView) -> NSRect {
        view.convert(view.bounds, to: root)
    }

    private func firstDescendant<T: NSView>(of view: NSView, _ type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T ?? firstDescendant(of: subview, type) { return match }
        }
        return nil
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
