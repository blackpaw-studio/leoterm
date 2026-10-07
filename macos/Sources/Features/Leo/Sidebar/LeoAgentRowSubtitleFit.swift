import AppKit

extension LeoAgentRowPresentation.Subtitle {
    /// The fewest template characters worth showing; any fewer ("clau…",
    /// "…") reads as noise, so the template drops instead (D-076).
    static let minimumTemplateCharacters = 5

    /// The line as it fits `width`: whole when it can. The usage gives way
    /// first, by whole components from the right ("37% ctx", then "$0.42"),
    /// never a partial number; then the template drops if it would show
    /// fewer than `minimumTemplateCharacters`. The state and the time always
    /// stay, and a template with nothing beside it is never dropped.
    /// `measure` gives a string's drawn width.
    func fitting(width: CGFloat, measure: (String) -> CGFloat) -> Self {
        guard let usage else { return fittingTemplate(width: width, measure: measure) }
        let parts = usage.components(separatedBy: Self.separator)
        for count in stride(from: parts.count, through: 1, by: -1) {
            let candidate = withUsage(parts.prefix(count).joined(separator: Self.separator))
            if measure(candidate.text) <= width { return candidate }
        }
        let bare = withUsage(nil)
        // A usage with nothing beside it keeps its first component.
        if bare.text.isEmpty { return withUsage(parts[0]) }
        return bare.fittingTemplate(width: width, measure: measure)
    }

    private func withUsage(_ usage: String?) -> Self {
        var copy = self
        copy.usage = usage
        return copy
    }

    private func fittingTemplate(width: CGFloat, measure: (String) -> CGFloat) -> Self {
        guard let template, state != nil || lastActive != nil else { return self }
        let rest = Self(template: nil, state: state, lastActive: lastActive, lastActiveSpoken: lastActiveSpoken,
                        usage: usage, usageTooltip: usageTooltip, usageSpoken: usageSpoken)
        let restWidth = measure(rest.text)
        // The whole template first: a narrow one can be slimmer than its
        // own five-character truncation.
        if width >= measure(template + Self.separator) + restWidth { return self }
        guard template.count > Self.minimumTemplateCharacters else { return rest }
        let legible = String(template.prefix(Self.minimumTemplateCharacters)) + "…"
        return width >= measure(legible + Self.separator) + restWidth ? self : rest
    }

    /// Drawn width in the subtitle's font (SwiftUI's `.caption`).
    static func captionWidth(_ text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
