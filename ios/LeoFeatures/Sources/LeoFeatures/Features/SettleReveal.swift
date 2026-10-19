import ComposableArchitecture
import LeoKit

/// Which questions card to bring back into view once it settles. A settled
/// card is far shorter than an open one and can end up above the screen, but
/// only a card the user just submitted or dismissed here is worth scrolling
/// to: a timeout or a terminal answer arriving while they read newer
/// messages must leave the thread where it is.
public struct SettleReveal: Equatable, Sendable {
    private var claims: Set<String> = []

    public init() {}

    /// The user submitted or dismissed `messageID` on this device.
    public mutating func acted(on messageID: String) {
        claims.insert(messageID)
    }

    /// The claimed card to reveal now, if one just settled. A claim is spent
    /// on the first reveal, and dropped once its request ends with the card
    /// still open (a refused answer) or the card is gone.
    public mutating func settled(
        in messages: IdentifiedArrayOf<LeoChatMessage>, answering: Set<String>
    ) -> String? {
        let ready = claims.subtracting(answering)
        claims.subtract(ready)
        return ready.first { messages[id: $0].map { !$0.isOpen } ?? false }
    }
}
