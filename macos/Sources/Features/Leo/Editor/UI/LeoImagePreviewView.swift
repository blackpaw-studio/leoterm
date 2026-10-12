import AppKit

/// Decodes previewed images (B-278) with ImageIO via `NSImage`: PNG, JPEG,
/// HEIC, WebP, GIF (animated) and SVG.
enum LeoImageDecode {
    static func image(contentsOf url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// An SVG drawn from its source text; nil when it doesn't decode.
    static func image(svg source: String) -> NSImage? {
        guard let image = NSImage(data: Data(source.utf8)), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// More than one frame: an animated GIF.
    static func isAnimated(_ image: NSImage) -> Bool {
        image.representations.contains { (($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 1) > 1 }
    }

    /// The image's pixels (its point size for a vector image).
    static func pixelSize(of image: NSImage) -> CGSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// A previewed image: fit to the pane (never enlarged past 100%) or at
/// actual size, toggled from View ▸ Actual Size / Zoom to Fit (⌥⌘0) or the
/// header, and pinch-zoomable. Small images sit centred. GIFs animate.
final class LeoImagePreviewView: NSView {
    let scrollView = NSScrollView()
    let imageView = NSImageView()
    private(set) var zoom = LeoImageZoom()
    /// The zoom changed (the header's button title follows it).
    var onZoomChange: () -> Void = {}
    private var magnifyObserver: NSObjectProtocol?

    init(image: NSImage, name: String) {
        super.init(frame: .zero)
        build(image: image, name: name)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
    }

    override var acceptsFirstResponder: Bool { true }

    func toggleZoom() {
        zoom = zoom.toggled()
        applyZoom()
        onZoomChange()
    }

    override func layout() {
        super.layout()
        if let magnification = zoom.magnificationAfterResize(image: imageSize, viewport: scrollView.contentSize) {
            scrollView.magnification = magnification
        }
    }

    private var imageSize: CGSize { imageView.image?.size ?? .zero }

    private func applyZoom() {
        guard let magnification = zoom.magnification(image: imageSize, viewport: scrollView.contentSize) else { return }
        scrollView.magnification = magnification
    }

    private func build(image: NSImage, name: String) {
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.setAccessibilityLabel(name)

        scrollView.contentView = LeoCenteringClipView()
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 16
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.zoom = self.zoom.pinched()
                self.onZoomChange()
            }
        }
    }
}

/// Keeps a document smaller than the visible area centred in it.
final class LeoCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}
