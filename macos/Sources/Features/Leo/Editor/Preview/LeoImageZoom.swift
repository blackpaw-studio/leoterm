import CoreGraphics

/// How a previewed image is scaled (B-278): fit to the pane -- shrinking a
/// big image, never enlarging a small one past 100% -- or actual size.
/// A pinch leaves both (`manual`) until the next toggle, which fits.
struct LeoImageZoom: Equatable {
    enum Mode: Equatable {
        case fit
        case actual
        case manual
    }

    private(set) var mode = Mode.fit

    /// The largest magnification at most 1 that shows all of `image` in
    /// `viewport`; 1 when either is empty.
    static func fitMagnification(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, viewport.width / image.width, viewport.height / image.height)
    }

    /// Fit ↔ actual; from a pinch, back to fit.
    func toggled() -> LeoImageZoom {
        LeoImageZoom(mode: mode == .fit ? .actual : .fit)
    }

    func pinched() -> LeoImageZoom {
        LeoImageZoom(mode: .manual)
    }

    /// What to set now; nil leaves the user's pinch as it is.
    func magnification(image: CGSize, viewport: CGSize) -> CGFloat? {
        switch mode {
        case .fit: Self.fitMagnification(image: image, viewport: viewport)
        case .actual: 1
        case .manual: nil
        }
    }

    /// Only a fitted image follows the pane's size.
    func magnificationAfterResize(image: CGSize, viewport: CGSize) -> CGFloat? {
        mode == .fit ? Self.fitMagnification(image: image, viewport: viewport) : nil
    }
}
