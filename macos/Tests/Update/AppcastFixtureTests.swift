import Testing
import Foundation

/// Reads a verbatim copy of the published appcast
/// (`https://github.com/blackpaw-studio/leoterm/releases/latest/download/appcast.xml`)
/// the way Sparkle does: the newest item is the highest `sparkle:version`,
/// and its enclosure carries the download URL, length and EdDSA signature.
///
/// Refreshing the fixture: `Fixtures/appcast.xml` is a snapshot, not a live
/// fetch, so these tests never touch the network. The newest-item values
/// below (`newestVersion`, `newestShortVersion`) are read off that snapshot,
/// so the fixture and those constants must be refreshed together, in one
/// commit. To refresh, from the repo root:
///
///     curl -fsSL -o macos/Tests/Update/Fixtures/appcast.xml \
///       https://github.com/blackpaw-studio/leoterm/releases/latest/download/appcast.xml
///
/// then set `newestVersion` to the highest `<sparkle:version>` in the new file
/// and `newestShortVersion` to that item's `<sparkle:shortVersionString>`.
/// Copy the file verbatim; never hand-edit it.
struct AppcastFixtureTests {
    /// Highest `sparkle:version` in `Fixtures/appcast.xml`. Refresh with the fixture.
    static let newestVersion = 18527
    /// `sparkle:shortVersionString` of that item. Refresh with the fixture.
    static let newestShortVersion = "0.5.0"

    @Test func newestItemIsRead() throws {
        let items = try AppcastFixture.load().items
        #expect(!items.isEmpty)

        let newest = try #require(items.max { $0.version < $1.version })
        #expect(newest.version == Self.newestVersion)
        #expect(newest.shortVersion == Self.newestShortVersion)

        let url = try #require(newest.enclosureURL.flatMap(URL.init(string:)))
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path.hasPrefix("/blackpaw-studio/leoterm/releases/"))

        let signature = try #require(newest.edSignature.flatMap { Data(base64Encoded: $0) })
        #expect(signature.count == 64)
        #expect((newest.length ?? 0) > 0)
    }

    @Test func everyItemIsSigned() throws {
        let items = try AppcastFixture.load().items
        for item in items {
            let signature = item.edSignature.flatMap { Data(base64Encoded: $0) }
            #expect(signature?.count == 64, "item \(item.version) has no valid edSignature")
        }
    }
}

/// A minimal, test-local reader for the appcast fields Leo relies on.
/// Sparkle's own `SUAppcast` initializer is private, and `SUAppcastItem`'s
/// dictionary initializer is deprecated, so the test reads the XML itself.
private struct AppcastFixture {
    struct Item {
        var version = 0
        var shortVersion: String?
        var enclosureURL: String?
        var edSignature: String?
        var length: Int?
    }

    let items: [Item]

    static func load() throws -> AppcastFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/appcast.xml")
        let reader = Reader()
        let parser = XMLParser(data: try Data(contentsOf: url))
        parser.delegate = reader
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return AppcastFixture(items: reader.items)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private(set) var items: [Item] = []
        private var current: Item?
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            text = ""
            switch elementName {
            case "item":
                current = Item()
            case "enclosure":
                current?.enclosureURL = attributes["url"]
                current?.edSignature = attributes["sparkle:edSignature"]
                current?.length = attributes["length"].flatMap(Int.init)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "sparkle:version":
                current?.version = Int(value) ?? 0
            case "sparkle:shortVersionString":
                current?.shortVersion = value
            case "item":
                if let current { items.append(current) }
                current = nil
            default:
                break
            }
        }
    }
}
