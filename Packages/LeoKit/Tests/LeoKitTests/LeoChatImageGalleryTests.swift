import Foundation
import Testing

@testable import LeoKit

struct LeoChatImageGalleryTests {
    private func attachment(_ id: String, mime: String = "image/png", available: Bool = true) -> LeoChatAttachment {
        LeoChatAttachment(id: id, filename: "\(id).png", mime: mime, bytes: 10, available: available)
    }

    private func message(_ attachments: [LeoChatAttachment]) -> LeoChatMessage {
        LeoChatMessage(id: "m", agent: "a", direction: .inbound, kind: .text, text: "", ts: Date(timeIntervalSince1970: 0), attachments: attachments)
    }

    @Test func keepsTheMessagesImagesInOrderAndStartsAtTheTappedOne() throws {
        let gallery = try #require(LeoChatImageGallery(
            message: message([attachment("a"), attachment("p", mime: "application/pdf"), attachment("b"), attachment("c")]), tappedID: "b"
        ))
        #expect(gallery.images.map(\.id) == ["a", "b", "c"])
        #expect(gallery.startIndex == 1)
    }

    @Test func leavesOutImagesNoLongerStored() throws {
        let gallery = try #require(LeoChatImageGallery(
            message: message([attachment("a", available: false), attachment("b"), attachment("c")]), tappedID: "c"
        ))
        #expect(gallery.images.map(\.id) == ["b", "c"])
        #expect(gallery.startIndex == 1)
    }

    @Test func aSingleImageIsAGalleryOfOne() throws {
        let gallery = try #require(LeoChatImageGallery(message: message([attachment("a")]), tappedID: "a"))
        #expect(gallery.images.map(\.id) == ["a"])
        #expect(gallery.startIndex == 0)
    }

    @Test func tappingSomethingOutsideTheGalleryGivesNone() {
        let msg = message([attachment("a"), attachment("p", mime: "application/pdf"), attachment("gone", available: false)])
        #expect(LeoChatImageGallery(message: msg, tappedID: "p") == nil)
        #expect(LeoChatImageGallery(message: msg, tappedID: "gone") == nil)
        #expect(LeoChatImageGallery(message: msg, tappedID: "nope") == nil)
    }
}
