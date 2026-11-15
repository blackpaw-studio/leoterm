#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// `-chatImagesFixture`: agent-0's thread holds one message of four images (the
/// third one tall) and, after it, a message of a single image, for driving the
/// full-screen image viewer. Layered on `-navFixture`.
enum ChatImagesFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-chatImagesFixture") }

    static let agent = "agent-0"
    static let multiID = "img-multi"
    static let singleID = "img-single"
    /// Attachment ids of the four-image message, in order.
    static let multiImageIDs = ["pic-1", "pic-2", "pic-3", "pic-4"]
    static let singleImageID = "pic-solo"

    private struct Picture {
        let digit: String
        let color: UIColor
        let size: CGSize
    }

    private static let pictures: [String: Picture] = [
        "pic-1": Picture(digit: "1", color: .systemTeal, size: CGSize(width: 600, height: 400)),
        "pic-2": Picture(digit: "2", color: .systemOrange, size: CGSize(width: 600, height: 400)),
        "pic-3": Picture(digit: "3", color: .systemPurple, size: CGSize(width: 400, height: 1_600)),
        "pic-4": Picture(digit: "4", color: .systemGreen, size: CGSize(width: 600, height: 400)),
        "pic-solo": Picture(digit: "A", color: .systemPink, size: CGSize(width: 600, height: 400))
    ]

    private static func attachment(_ id: String) -> LeoChatAttachment {
        LeoChatAttachment(id: id, filename: "\(id).png", mime: "image/png", bytes: 1_000)
    }

    static let messages: [LeoChatMessage] = {
        let start = Date().addingTimeInterval(-600)
        return [
            LeoChatMessage(
                id: multiID, agent: agent, direction: .outbound, kind: .text, text: "Four screenshots from the run.",
                ts: start, attachments: multiImageIDs.map(attachment)
            ),
            LeoChatMessage(
                id: singleID, agent: agent, direction: .outbound, kind: .text, text: "And one more.",
                ts: start.addingTimeInterval(60), attachments: [attachment(singleImageID)]
            )
        ]
    }()

    static func prepare(_ values: inout DependencyValues) {
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: messages, hasMore: false) }
        values.chatClient.download = { _, attachment in
            try await Task.sleep(for: .milliseconds(300))
            let picture = pictures[attachment.id] ?? Picture(digit: "?", color: .gray, size: CGSize(width: 600, height: 400))
            let url = URL.temporaryDirectory.appending(path: "\(attachment.id).png")
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let png = UIGraphicsImageRenderer(size: picture.size, format: format).pngData { context in
                picture.color.setFill()
                context.fill(CGRect(origin: .zero, size: picture.size))
                let side = min(picture.size.width, picture.size.height)
                let text = NSAttributedString(string: picture.digit, attributes: [
                    .font: UIFont.systemFont(ofSize: side * 0.6, weight: .heavy), .foregroundColor: UIColor.white
                ])
                let bounds = text.size()
                text.draw(at: CGPoint(x: (picture.size.width - bounds.width) / 2, y: (picture.size.height - bounds.height) / 2))
                UIColor.white.setStroke()
                context.cgContext.setLineWidth(8)
                context.cgContext.stroke(CGRect(origin: .zero, size: picture.size).insetBy(dx: 4, dy: 4))
            }
            try png.write(to: url)
            return url
        }
    }
}
#endif
