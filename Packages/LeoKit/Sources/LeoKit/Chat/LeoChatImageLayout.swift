import CoreGraphics
import Foundation
import ImageIO

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

    /// The narrowest a tall image's frame, and so its bubble, may be.
    public static let readableWidth: CGFloat = 200

    /// The frame to draw an image of `size` in. Like `displaySize`, but a
    /// narrow, tall image is widened to `readableWidth` so a caption beside it
    /// doesn't wrap a word per line. Draw aspect-fill; the frame crops.
    public static func frameSize(for size: CGSize) -> CGSize {
        let display = displaySize(for: size)
        guard display.width < readableWidth, display.height >= readableWidth else { return display }
        return CGSize(width: readableWidth, height: display.height)
    }

    /// The upright pixel size of the image file at `url`, read from its
    /// header, or `nil` when it isn't an image.
    public static func pixelSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // EXIF orientations 5...8 are rotated a quarter turn.
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
