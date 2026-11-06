import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import LeoKit

struct LeoPastedImageTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-31 09:24:05 UTC.
    private let date = Date(timeIntervalSince1970: 1_793_438_645)

    private static func encoded(_ type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
    }

    @Test func pngIsKeptAsIs() throws {
        let png = Self.encoded(.png)
        let image = try #require(LeoPastedImage(data: png, date: date, timeZone: utc))
        #expect(image.data == png)
        #expect(image.mime == "image/png")
        #expect(image.filename == "Pasted image 2026-10-31 09.24.05.png")
    }

    @Test func jpegIsKeptAsJPEG() throws {
        let jpeg = Self.encoded(.jpeg)
        let image = try #require(LeoPastedImage(data: jpeg, date: date, timeZone: utc))
        #expect(image.data == jpeg)
        #expect(image.mime == "image/jpeg")
        #expect(image.filename == "Pasted image 2026-10-31 09.24.05.jpg")
    }

    @Test func tiffIsConvertedToPNG() throws {
        let image = try #require(LeoPastedImage(data: Self.encoded(.tiff), date: date, timeZone: utc))
        #expect(Self.type(of: image.data) == UTType.png.identifier)
        #expect(image.mime == "image/png")
        #expect(image.filename.hasSuffix(".png"))
    }

    @Test func heicIsConvertedToPNG() throws {
        let heic = Self.encoded(.heic)
        let image = try #require(LeoPastedImage(data: heic, date: date, timeZone: utc))
        #expect(Self.type(of: image.data) == UTType.png.identifier)
        #expect(image.mime == "image/png")
    }

    @Test func nonImageDataIsRefused() {
        #expect(LeoPastedImage(data: Data("hello".utf8), date: date, timeZone: utc) == nil)
        #expect(LeoPastedImage(data: Data(), date: date, timeZone: utc) == nil)
    }

    @Test func nameFollowsTheTimeZone() throws {
        let eastern = TimeZone(identifier: "America/New_York")!
        let image = try #require(LeoPastedImage(data: Self.encoded(.png), date: date, timeZone: eastern))
        #expect(image.filename == "Pasted image 2026-10-31 05.24.05.png")
    }
}
