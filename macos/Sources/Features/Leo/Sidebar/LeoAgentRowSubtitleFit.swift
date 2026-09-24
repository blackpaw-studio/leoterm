import AppKit

extension LeoAgentRowPresentation.Subtitle {
    /// The fewest template characters worth showing; any fewer ("clau…",
    /// "…") reads as noise, so the template drops instead (D-076).
    static let minimumTemplateCharacters = 5

    /// The line as it fits `width`: whole when it can, otherwise without
    /// the template if the template would show fewer than
    /// `minimumTemplateCharacters`. The state and the time always stay, and
    /// a template with nothing beside it is never dropped. `measure` gives
    /// a string's drawn width.
    func fitting(width: CGFloat, measure: (String) -> CGFloat) -> Self {
        guard let template, state != nil || lastActive != nil else { return self }
        let rest = Self(template: nil, state: state, lastActive: lastActive, lastActiveSpoken: lastActiveSpoken)
        let legible = template.count > Self.minimumTemplateCharacters
            ? String(template.prefix(Self.minimumTemplateCharacters)) + "…"
            : template
        return width >= measure(legible + Self.separator) + measure(rest.text) ? self : rest
    }

    /// Drawn width in the subtitle's font (SwiftUI's `.caption`).
    static func captionWidth(_ text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
