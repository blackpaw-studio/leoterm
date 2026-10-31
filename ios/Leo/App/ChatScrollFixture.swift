#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// `-chatScrollFixture`: agent-0's thread is long enough to scroll, with
/// multi-line bubbles, an image that loads late, and an older page behind it.
/// Sending echoes the message back. Layered on `-navFixture`.
enum ChatScrollFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-chatScrollFixture") }

    static let agent = "agent-0"
    static let imageID = "scroll-image"
    private static let start = Date().addingTimeInterval(-3 * 3_600)

    private static func message(_ id: String, index: Int, text: String, attachments: [LeoChatAttachment] = []) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: index.isMultiple(of: 3) ? .inbound : .outbound, kind: .text, text: text,
            state: index.isMultiple(of: 3) ? "delivered" : nil,
            ts: start.addingTimeInterval(Double(index) * 120), attachments: attachments
        )
    }

    private static func text(for index: Int) -> String {
        switch index % 4 {
        case 0: "Short note \(index)."
        case 1: (1...(3 + index % 5)).map { "Line \($0) of message \(index), long enough to wrap onto a second line on a phone." }.joined(separator: "\n")
        case 2: "Message \(index): a mid-sized paragraph that wraps a couple of times on a narrow screen."
        default: "Reply \(index)"
        }
    }

    /// The newest page: 50 messages (one page) ending in an image.
    static let newest: [LeoChatMessage] = (20..<70).map { index in
        message(
            "s\(index)", index: index, text: text(for: index),
            attachments: index == 69 ? [LeoChatAttachment(id: imageID, filename: "shot.png", mime: "image/png", bytes: 1_000)] : []
        )
    }

    /// The page above it, for the load-older scroll-position check.
    static let older: [LeoChatMessage] = (0..<20).map { message("s\(String(format: "%02d", $0))", index: $0, text: text(for: $0)) }

    static func prepare(_ values: inout DependencyValues) {
        let sentCount = LockIsolated(0)
        values.chatClient.messages = { _, _, query in
            query.before == nil ? LeoChatPage(messages: newest, hasMore: true) : LeoChatPage(messages: older, hasMore: false)
        }
        values.chatClient.send = { _, agent, draft in
            let count = sentCount.withValue { $0 += 1; return $0 }
            return LeoChatMessage(
                id: "zz-sent-\(count)", agent: agent, direction: .inbound, kind: .text, text: draft.text, state: "delivered", ts: Date()
            )
        }
        values.chatClient.download = { _, attachment in
            try await Task.sleep(for: .milliseconds(600))
            let url = URL.temporaryDirectory.appending(path: "\(attachment.id).png")
            let png = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
            try png.write(to: url)
            return url
        }
    }
}
#endif
