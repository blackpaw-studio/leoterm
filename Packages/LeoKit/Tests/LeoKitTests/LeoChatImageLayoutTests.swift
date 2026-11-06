import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import LeoKit

struct LeoChatImageLayoutTests {
    typealias Layout = LeoChatImageLayout

    @Test func aTallNarrowImageKeepsABubbleWideEnoughToRead() {
        #expect(Layout.displaySize(for: CGSize(width: 400, height: 4000)) == CGSize(width: 130, height: 260))
        #expect(Layout.displaySize(for: CGSize(width: 100, height: 2000)) == CGSize(width: 100, height: 200))
        #expect(Layout.displaySize(for: CGSize(width: 40, height: 200)) == CGSize(width: 40, height: 80))
    }

    @Test func aWideImageFitsTheMaxWidth() {
        #expect(Layout.displaySize(for: CGSize(width: 1000, height: 500)) == CGSize(width: 260, height: 130))
    }

    @Test func aSmallImageIsNotScaledUp() {
        #expect(Layout.displaySize(for: CGSize(width: 80, height: 60)) == CGSize(width: 80, height: 60))
    }

    @Test func anEmptyImageHasNoSize() {
        #expect(Layout.displaySize(for: .zero) == .zero)
    }

    // A tall image plus a caption must not leave a bubble ~130 pt wide (the B-343 report).
    @Test func aTallImageFrameIsAtLeastReadableWidth() {
        #expect(Layout.frameSize(for: CGSize(width: 300, height: 3000)) == CGSize(width: 200, height: 260))
        #expect(Layout.frameSize(for: CGSize(width: 100, height: 2000)) == CGSize(width: 200, height: 200))
    }

    @Test func nonTallImagesKeepTheirDisplaySize() {
        #expect(Layout.frameSize(for: CGSize(width: 1000, height: 500)) == CGSize(width: 260, height: 130))
        #expect(Layout.frameSize(for: CGSize(width: 80, height: 60)) == CGSize(width: 80, height: 60))
    }

    @Test func pixelSizeComesFromTheFileNotAThumbnail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("b343-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(
            data: nil, width: 40, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        #expect(Layout.pixelSize(ofImageAt: url) == CGSize(width: 40, height: 400))
        #expect(Layout.pixelSize(ofImageAt: url.appendingPathExtension("missing")) == nil)
    }
}
