import Foundation
import LeoKit
import QuickLook
import UIKit

/// How chat messages read in lists and cells.
enum ChatPresentation {
    /// Text longer than this collapses behind "Show more".
    static let collapsedCharacterLimit = 600
    static let collapsedLineLimit = 12

    /// One line for the Chats list.
    static func preview(_ message: LeoChatMessage) -> String {
        let body = switch message.kind {
        case .voice: message.transcript.map { "🎤 \($0)" } ?? String(localized: "🎤 Voice note")
        case .file: message.text.isEmpty ? "📎 \(message.attachments.first?.filename ?? String(localized: "Attachment"))" : "📎 \(message.text)"
        case .task: "\(message.task ?? String(localized: "Task")): \(message.text)"
        case .ask: "❓ \(message.text)"
        case .permission: String(localized: "Permission: \(message.text)")
        case .system, .text, .unknown:
            message.text.isEmpty && !message.attachments.isEmpty ? "📎 \(message.attachments[0].filename)" : message.text
        }
        let flat = body.replacingOccurrences(of: "\n", with: " ")
        return message.direction == .inbound ? String(localized: "You: \(flat)") : flat
    }

    static func time(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func isLong(_ text: String) -> Bool {
        text.count > collapsedCharacterLimit || text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } >= collapsedLineLimit
    }

    static func stateLine(_ message: LeoChatMessage) -> String? {
        guard message.direction == .inbound else { return nil }
        return switch message.state {
        case "pending": String(localized: "Sending…")
        case "failed": String(localized: "Not delivered")
        case "delivered": String(localized: "Delivered")
        default: nil
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// QuickLook over one local file.
final class ChatQuickLookController: QLPreviewController, QLPreviewControllerDataSource {
    private let item: Item

    init(url: URL, title: String) {
        item = Item(previewItemURL: url, previewItemTitle: title)
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }

    private final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(previewItemURL: URL, previewItemTitle: String) {
            self.previewItemURL = previewItemURL
            self.previewItemTitle = previewItemTitle
        }
    }
}
