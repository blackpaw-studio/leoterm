import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Ghostty

/// The image formats the pane previews (B-278) decode at their real size,
/// and GIFs animate.
@MainActor
struct LeoImageDecodeTests {
    /// A 1×1 lossless WebP (the well-known feature-detection image).
    static let webP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!

    private static func cgImage(width: Int, height: Int, red: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Encodes `frames` with ImageIO as `type`.
    static func encode(_ type: UTType, frames: [CGImage]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames.count, nil))
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func decoded(_ data: Data, _ name: String) throws -> NSImage {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let url = URL(fileURLWithPath: sandbox.path(name))
        try data.write(to: url)
        return try #require(LeoImageDecode.image(contentsOf: url), "\(name) didn't decode")
    }

    @Test(arguments: [("a.png", UTType.png), ("a.jpg", .jpeg), ("a.heic", .heic)])
    func bitmapsDecodeAtTheirSize(_ name: String, _ type: UTType) throws {
        let image = try decoded(try Self.encode(type, frames: [Self.cgImage(width: 30, height: 20)]), name)
        #expect(LeoImageDecode.pixelSize(of: image) == CGSize(width: 30, height: 20))
        #expect(!LeoImageDecode.isAnimated(image))
    }

    @Test func webPDecodes() throws {
        #expect(LeoImageDecode.pixelSize(of: try decoded(Self.webP, "a.webp")) == CGSize(width: 1, height: 1))
    }

    @Test func svgDecodesFromItsSource() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let image = try #require(LeoImageDecode.image(svg: svg))
        #expect(image.size == CGSize(width: 40, height: 20))
        #expect(LeoImageDecode.image(svg: "<svg") == nil)
    }

    @Test func gifAnimates() throws {
        let frames = [Self.cgImage(width: 8, height: 8, red: 1), Self.cgImage(width: 8, height: 8, red: 0)]
        let image = try decoded(try Self.encode(.gif, frames: frames), "a.gif")
        #expect(LeoImageDecode.isAnimated(image))
        #expect(LeoImagePreviewView(image: image, name: "a.gif").imageView.animates)
    }

    @Test func garbageDoesNotDecode() throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let url = URL(fileURLWithPath: try sandbox.file("a.png", "not a png"))
        #expect(LeoImageDecode.image(contentsOf: url) == nil)
    }
}
