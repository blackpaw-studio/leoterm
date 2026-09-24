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

            // Drawn, not just laid out: the header's name, path and mode, and
            // the separator under it, still show above the banner.
            #expect(!recents.title.isEmpty)
            let separator = try #require(pane.view.subviews.first { $0 is NSBox })
            #expect(!separator.isHidden && frame(of: separator, in: pane.view).midY >= bannerFrame.maxY)
            let pixels = try #require(render(pane.view))
            #expect(distinctColors(in: pixels, rect: headerFrame, of: pane.view) > 1, "the header isn't painted over")

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

    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Colours in `rect` (in `view`'s coordinates) of its rendering.
    private func distinctColors(in rep: NSBitmapImageRep, rect: NSRect, of view: NSView) -> Int {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let flipped = view.isFlipped
        var colors = Set<String>()
        for y in stride(from: rect.minY + 1, to: rect.maxY - 1, by: 1) {
            for x in stride(from: rect.minX + 1, to: rect.maxX - 1, by: 1) {
                let py = Int((flipped ? y : view.bounds.height - y) * scale)
                guard let color = rep.colorAt(x: Int(x * scale), y: min(py, rep.pixelsHigh - 1)) else { continue }
                colors.insert(color.description)
            }
        }
        return colors.count
    }

    /// Drawing a banner never paints outside it: with `clipsToBounds` off
    /// (the default since macOS 14), AppKit may pass a dirty rect larger
    /// than the view, and filling that painted over the header above it.
    @Test func theBannerPaintsOnlyItsOwnBounds() throws {
        let banner = LeoEditorBannerView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        banner.draw(NSRect(x: 0, y: 0, width: 100, height: 60))
        NSGraphicsContext.restoreGraphicsState()

        #expect(rep.colorAt(x: 50, y: 50)?.alphaComponent != 0, "its own bounds are filled")
        #expect(rep.colorAt(x: 50, y: 5)?.alphaComponent == 0, "nothing above it is")
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
