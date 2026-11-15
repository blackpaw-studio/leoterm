import AppKit
import Foundation
import Testing

@testable import Ghostty

struct LeoImagePasteTests {
    private struct Row: CustomTestStringConvertible {
        let key: LeoImagePaste.Key
        let hasImage: Bool
        let hasText: Bool
        let expectedOnRemoteAgent: LeoImagePaste.Decision
        var testDescription: String { "\(key) image=\(hasImage) text=\(hasText)" }
    }

    private static let rows: [Row] = [
        Row(key: .controlV, hasImage: true, hasText: false, expectedOnRemoteAgent: .uploadImage),
        Row(key: .controlV, hasImage: true, hasText: true, expectedOnRemoteAgent: .uploadImage),
        Row(key: .controlV, hasImage: false, hasText: true, expectedOnRemoteAgent: .passThrough),
        Row(key: .controlV, hasImage: false, hasText: false, expectedOnRemoteAgent: .passThrough),
        Row(key: .commandV, hasImage: true, hasText: false, expectedOnRemoteAgent: .uploadImage),
        Row(key: .commandV, hasImage: true, hasText: true, expectedOnRemoteAgent: .passThrough),
        Row(key: .commandV, hasImage: false, hasText: true, expectedOnRemoteAgent: .passThrough),
        Row(key: .commandV, hasImage: false, hasText: false, expectedOnRemoteAgent: .passThrough),
    ]

    /// The spec's table on a remote agent; every other surface keeps today's
    /// behaviour whatever is on the clipboard.
    @Test(arguments: rows, LeoImagePaste.SurfaceKind.allCases)
    private func decisionTable(row: Row, surface: LeoImagePaste.SurfaceKind) {
        let decision = LeoImagePaste.decide(key: row.key, hasImage: row.hasImage, hasText: row.hasText, surface: surface)
        #expect(decision == (surface == .remoteAgent ? row.expectedOnRemoteAgent : .passThrough))
    }

    // MARK: Pasteboard

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("leo-image-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return rep
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test func tiffOnlyClipboardConvertsToPNGAtTheOriginalPixelSize() throws {
        let board = pasteboard()
        let tiff = try #require(try bitmap(width: 5, height: 3).tiffRepresentation)
        board.setData(tiff, forType: .tiff)

        #expect(LeoImagePaste.hasImage(board))
        let png = try #require(LeoImagePaste.pngData(from: board))
        #expect(png.prefix(8) == Self.pngSignature)
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect((decoded.pixelsWide, decoded.pixelsHigh) == (5, 3))
    }

    @Test func pngOnClipboardIsPassedThroughUntouched() throws {
        let board = pasteboard()
        let png = try #require(try bitmap(width: 2, height: 2).representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)

        #expect(LeoImagePaste.pngData(from: board) == png)
    }

    @Test func scratchDirectoryIsTheUsersCacheUnderHome() {
        #expect(LeoImagePaste.scratchDirectory(home: "/Users/evan") == "/Users/evan/.cache/leo/paste")
        #expect(LeoImagePaste.scratchDirectory(home: "/") == "/.cache/leo/paste")
    }

    @Test func textOnlyClipboardHasNoImage() {
        let board = pasteboard()
        board.setString("hello", forType: .string)

        #expect(!LeoImagePaste.hasImage(board))
        #expect(LeoImagePaste.hasText(board))
        #expect(LeoImagePaste.pngData(from: board) == nil)
    }

    @Test func imageOnlyClipboardHasNoText() throws {
        let board = pasteboard()
        board.setData(try #require(try bitmap(width: 1, height: 1).tiffRepresentation), forType: .tiff)

        #expect(!LeoImagePaste.hasText(board))
    }

    /// Finder puts the file URL, its name and the file's icon (TIFF) on the
    /// pasteboard when a file is copied. That is a file, not an image paste.
    @Test func copiedFileWithItsIconIsNotAnImage() throws {
        let board = pasteboard()
        board.setData(try #require(try bitmap(width: 2, height: 2).tiffRepresentation), forType: .tiff)
        board.addTypes([.fileURL], owner: nil)
        board.setString(URL(fileURLWithPath: "/tmp/report.txt").absoluteString, forType: .fileURL)

        #expect(!LeoImagePaste.hasImage(board))
    }
}
