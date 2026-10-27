import AppKit
import SwiftUI

/// A symbol that turns steadily, drawn and turned by Core Animation: the
/// render server runs the rotation, so a turning row costs the main thread
/// nothing per frame. A SwiftUI `rotationEffect` with a repeating animation
/// instead re-rendered its hosting view every frame, and each frame laid
/// out the whole window -- with several working agents, most of the main
/// thread's time.
struct LeoSpinningSymbolView: NSViewRepresentable {
    let symbolName: String
    let color: NSColor
    /// One full turn, clockwise.
    let period: Double

    func makeNSView(context: Context) -> LeoSpinningSymbolNSView {
        let view = LeoSpinningSymbolNSView()
        view.update(symbolName: symbolName, color: color, period: period)
        return view
    }

    func updateNSView(_ view: LeoSpinningSymbolNSView, context: Context) {
        view.update(symbolName: symbolName, color: color, period: period)
    }
}

/// Layer-hosting, so its symbol layer's geometry is its own (AppKit resets
/// a layer-backed view's anchor point and transform).
final class LeoSpinningSymbolNSView: NSView {
    private static let rotationKey = "leo.spin"
    private let symbolLayer = CALayer()
    private var symbolName = ""
    private var color = NSColor.clear
    private var period = 1.0

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        symbolLayer.contentsGravity = .center
        layer?.addSublayer(symbolLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// Clicks and right-clicks go through to the row beneath: its
    /// selection, its click catcher and its context menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(symbolName: String, color: NSColor, period: Double) {
        let redraws = symbolName != self.symbolName || color != self.color
        let respins = period != self.period
        self.symbolName = symbolName
        self.color = color
        self.period = period
        if redraws { drawSymbol() }
        if respins { symbolLayer.removeAnimation(forKey: Self.rotationKey) }
        spin()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawSymbol()
        spin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawSymbol()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawSymbol()
    }

    /// Renders under this view's appearance, so a dynamic system colour
    /// resolves for light or dark.
    private func drawSymbol() {
        let configuration = NSImage.SymbolConfiguration(textStyle: .body)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var contents: Any?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contents = image.layerContents(forContentsScale: scale)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.contents = contents
        symbolLayer.contentsScale = scale
        symbolLayer.bounds = CGRect(origin: .zero, size: image.size)
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    /// Clockwise: AppKit layers aren't flipped, so a negative angle.
    private func spin() {
        guard symbolLayer.animation(forKey: Self.rotationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi
        rotation.duration = period
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        symbolLayer.add(rotation, forKey: Self.rotationKey)
    }
}
