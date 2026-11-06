import CoreGraphics

/// How big an image attachment is drawn inside a chat bubble, shared by the
/// Mac and iOS chats so both size it the same way.
public enum LeoChatImageLayout {
    /// The longest either side of an inline image may be.
    public static let maxSide: CGFloat = 260
    /// The tallest an image may be drawn relative to its width. A taller image
    /// (a long screenshot) is cropped to this, so its bubble stays readable.
    public static let maxHeightToWidth: CGFloat = 2

    /// The frame to draw an image of `size` in: scaled down to fit `maxSide`,
    /// never scaled up, and no taller than `maxHeightToWidth` times its width.
    /// Draw the image aspect-fill so an over-tall one is cropped to the frame.
    public static func displaySize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let height = min(size.height, size.width * maxHeightToWidth)
        let scale = min(1, maxSide / size.width, maxSide / height)
        return CGSize(width: size.width * scale, height: height * scale)
    }
}
