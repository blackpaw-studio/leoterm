import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image pasted into the chat composer, ready to attach: JPEG stays
/// JPEG, PNG stays PNG, anything else (TIFF, HEIC) is re-encoded as PNG.
public struct LeoPastedImage: Equatable, Sendable {
    public let data: Data
    public let filename: String
    public let mime: String

    /// `nil` when `data` is not an image ImageIO can read and re-encode.
    public init?(data: Data, date: Date = Date(), timeZone: TimeZone = .current) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source).map({ $0 as String }),
              let type = UTType(typeIdentifier)
        else { return nil }
        let kept: (data: Data, type: UTType)
        if type == .png || type == .jpeg {
            kept = (data, type)
        } else {
            guard let png = Self.pngData(from: source) else { return nil }
            kept = (png, .png)
        }
        guard let ext = kept.type.preferredFilenameExtension, let mime = kept.type.preferredMIMEType else { return nil }
        self.data = kept.data
        self.mime = mime
        self.filename = "Pasted image \(Self.stamp(date, in: timeZone)).\(ext == "jpeg" ? "jpg" : ext)"
    }

    private static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func pngData(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
