import Foundation

/// Chat message text as an `AttributedString`: inline Markdown, plus bare URLs
/// turned into links. Shared so the Mac and iOS bubbles agree on what is a link.
public enum LeoChatText {
    /// The only schemes a chat message may link to. Anything else (`file:`,
    /// `javascript:`, …) renders as plain text.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return autolinked(strippingDisallowedLinks(parsed))
    }

    private static func isAllowed(_ url: URL) -> Bool {
        url.scheme.map { allowedSchemes.contains($0.lowercased()) } ?? false
    }

    private static func strippingDisallowedLinks(_ source: AttributedString) -> AttributedString {
        var result = source
        for run in source.runs {
            if let url = run.link, !isAllowed(url) { result[run.range].link = nil }
        }
        return result
    }

    private static func autolinked(_ source: AttributedString) -> AttributedString {
        let plain = String(source.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return source
        }
        var result = source
        let whole = NSRange(plain.startIndex..., in: plain)
        for match in detector.matches(in: plain, options: [], range: whole) {
            guard let url = match.url, isAllowed(url), let stringRange = Range(match.range, in: plain) else { continue }
            let lower = result.index(
                result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: stringRange.lowerBound))
            let upper = result.index(
                lower, offsetByCharacters: plain.distance(from: stringRange.lowerBound, to: stringRange.upperBound))
            let range = lower..<upper
            guard isLinkable(result[range]) else { continue }
            result[range].link = url
        }
        return result
    }

    /// A span is left alone when any of it is already a link or inline code.
    private static func isLinkable(_ slice: AttributedSubstring) -> Bool {
        !slice.runs.contains { run in
            run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
        }
    }
}
