import Foundation

/// How a chat thread lays out as an iMessage-style transcript: time headers
/// after pauses, and consecutive bubbles from one sender grouped so only the
/// last one carries a tail. Pure logic shared by the Mac and iOS views.
public enum LeoChatTranscript {
    /// A pause at least this long puts a time header above the next message.
    public static let timeHeaderGap: TimeInterval = 15 * 60
    /// Bubbles closer together than this (same sender) belong to one group.
    public static let groupGap: TimeInterval = 60

    /// Where a bubble sits in its group.
    public enum GroupPosition: Equatable, Sendable { case single, first, middle, last }

    public enum Item: Equatable, Identifiable, Sendable {
        /// `id` is `time-<id of the message it precedes>`.
        case timeHeader(Date, id: String)
        case message(LeoChatMessage, position: GroupPosition)

        public var id: String {
            switch self {
            case .timeHeader(_, let id): id
            case .message(let message, _): message.id
            }
        }
    }

    /// The transcript for `messages`, which must be sorted by `(ts, id)`.
    public static func items(for messages: [LeoChatMessage]) -> [Item] {
        let hasHeader = messages.indices.map { index in
            index == 0 || messages[index].ts.timeIntervalSince(messages[index - 1].ts) >= timeHeaderGap
        }
        let joinsPrevious = messages.indices.map { index in
            index > 0 && !hasHeader[index] && joins(messages[index], after: messages[index - 1])
        }
        return messages.indices.flatMap { index -> [Item] in
            let joinsNext = index + 1 < messages.count && joinsPrevious[index + 1]
            let message = messages[index]
            let item = Item.message(message, position: position(joinsPrevious: joinsPrevious[index], joinsNext: joinsNext))
            return hasHeader[index] ? [.timeHeader(message.ts, id: "time-\(message.id)"), item] : [item]
        }
    }

    private static func position(joinsPrevious: Bool, joinsNext: Bool) -> GroupPosition {
        switch (joinsPrevious, joinsNext) {
        case (false, false): .single
        case (false, true): .first
        case (true, true): .middle
        case (true, false): .last
        }
    }

    private static let bubbleKinds: Set<LeoChatMessage.Kind> = [.text, .voice, .file, .ask, .permission]

    private static func joins(_ message: LeoChatMessage, after previous: LeoChatMessage) -> Bool {
        bubbleKinds.contains(message.kind) && bubbleKinds.contains(previous.kind)
            && message.direction == previous.direction
            && (message.ts.timeIntervalSince(previous.ts) < groupGap || message.continuesPost(after: previous))
    }
}
