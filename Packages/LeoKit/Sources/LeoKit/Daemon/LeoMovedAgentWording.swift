import Foundation

/// B-324: what Delete says for a moved agent's dormant record. The daemon
/// removes the source host's worktree (and its branch only when merged) and
/// leaves the destination alone, so the prompt names the leftover, not the agent.
public enum LeoMovedAgentWording {
    public static let removeLeftoverButton = "Remove"

    public static func removeLeftoverTitle(on source: String, movedTo host: String) -> String {
        "Remove leftover copy on \(source) (the agent lives on \(host))"
    }
}

extension LeoMovedAgentWording {
    /// The daemon's `moved_at`: RFC 3339, with fractional seconds when the
    /// instant has them (Go omits a zero fraction), so both shapes parse.
    public static func date(from timestamp: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) { return date }
        // Nanosecond fractions are longer than the formatter accepts: trim to milliseconds.
        guard let dot = timestamp.firstIndex(of: "."), let zone = timestamp[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        let millis = timestamp[timestamp.index(after: dot)..<zone].prefix(3)
        return fractional.date(from: String(timestamp[..<dot]) + "." + millis + String(timestamp[zone...]))
    }

    /// "Moved to nas · 5 minutes ago"; the host alone when there is no readable time.
    public static func movedText(host: String, at timestamp: String?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let timestamp, let date = date(from: timestamp) else { return "Moved to \(host)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return "Moved to \(host) · \(formatter.localizedString(for: date, relativeTo: now))"
    }
}
