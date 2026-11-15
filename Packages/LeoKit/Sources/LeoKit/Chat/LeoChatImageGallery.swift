import Foundation

/// The images a full-screen viewer pages through when one image of a message
/// is opened: that message's stored image attachments, in order, and where the
/// tapped one sits among them.
public struct LeoChatImageGallery: Equatable, Sendable {
    public let images: [LeoChatAttachment]
    public let startIndex: Int

    /// `nil` when `tappedID` isn't a stored image of `message`.
    public init?(message: LeoChatMessage, tappedID: String) {
        let images = message.attachments.filter { $0.isImage && $0.available }
        guard let start = images.firstIndex(where: { $0.id == tappedID }) else { return nil }
        self.images = images
        startIndex = start
    }
}
