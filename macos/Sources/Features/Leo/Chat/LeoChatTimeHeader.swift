import LeoKit
import SwiftUI

/// The centred time above a pause in the thread: "Today 1:06 PM", with the
/// day in semibold, as in iMessage.
struct LeoChatTimeHeader: View {
    let date: Date
    let now: Date

    var body: some View {
        Text(Self.attributed(date, now: now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("chat.timeHeader")
    }

    static func attributed(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> AttributedString {
        let header = LeoChatTranscript.headerText(date, calendar: calendar, now: now)
        var text = AttributedString(header.text)
        if let range = text.range(of: header.day) { text[range].font = .caption.weight(.semibold) }
        return text
    }
}
