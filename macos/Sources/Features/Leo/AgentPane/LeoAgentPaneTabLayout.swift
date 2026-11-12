import CoreGraphics

/// How the pane's tab bar draws its tabs in a given width. Pure, so the
/// overflow rules are tested without measuring a view: the caller measures
/// each tab and this decides what to draw.
///
/// In order, it tries:
/// 1. every tab with its summary;
/// 2. the selected tab with its summary, the others as titles;
/// 3. every tab as a title;
/// 4. titles for the selected tab and as many others as fit (in original
///    order), the rest behind one "+N" button.
struct LeoAgentPaneTabLayout: Equatable {
    struct Tab: Equatable {
        let id: String
        /// The width of the tab drawn as its title only.
        let titleWidth: Double
        /// The width of the tab drawn with its summary. Equal to `titleWidth`
        /// (or less) for a tab that has no summary.
        let fullWidth: Double
    }

    enum Presentation: Equatable {
        case full
        case titleOnly
        /// Not drawn; counted in the "+N" button.
        case overflow
    }

    struct Entry: Equatable {
        let id: String
        let presentation: Presentation
    }

    /// One entry per input tab, in input order.
    let entries: [Entry]

    var overflowCount: Int { entries.count { $0.presentation == .overflow } }
    var overflowLabel: String? { overflowCount > 0 ? "+\(overflowCount)" : nil }

    /// - Parameters:
    ///   - selected: the selected tab's id; nil or not a tab means no selection.
    ///   - width: the room for the whole bar, excluding the chevron.
    ///   - spacing: the gap between neighbouring tabs, and before "+N".
    ///   - overflowWidth: the "+N" button's width.
    static func fit(
        tabs: [Tab], selected: String?, width: Double, spacing: Double, overflowWidth: Double
    ) -> LeoAgentPaneTabLayout {
        func extent(_ widths: [Double]) -> Double {
            widths.reduce(0, +) + spacing * Double(max(0, widths.count - 1))
        }
        func layout(_ presentation: (Tab) -> Presentation) -> LeoAgentPaneTabLayout {
            LeoAgentPaneTabLayout(entries: tabs.map { Entry(id: $0.id, presentation: presentation($0)) })
        }
        guard !tabs.isEmpty else { return LeoAgentPaneTabLayout(entries: []) }

        func summaryOrTitle(_ tab: Tab) -> Presentation { tab.fullWidth > tab.titleWidth ? .full : .titleOnly }

        if extent(tabs.map(\.fullWidth)) <= width {
            return layout(summaryOrTitle)
        }
        let selectedIndex = tabs.firstIndex { $0.id == selected }
        let selectedFull = tabs.enumerated().map { $0.offset == selectedIndex ? $0.element.fullWidth : $0.element.titleWidth }
        if selectedIndex != nil, extent(selectedFull) <= width {
            return layout { $0.id == selected ? summaryOrTitle($0) : .titleOnly }
        }
        if extent(tabs.map(\.titleWidth)) <= width {
            return layout { _ in .titleOnly }
        }

        // Titles don't fit: reserve the "+N" button, force the selected tab,
        // then take the others in order while they fit. Each tab costs its
        // width plus the gap after it, which also pays for the gap before "+N".
        var remaining = width - overflowWidth
        var shown = Set<Int>()
        if let selectedIndex {
            shown.insert(selectedIndex)
            remaining -= tabs[selectedIndex].titleWidth + spacing
        }
        for index in tabs.indices where index != selectedIndex {
            let cost = tabs[index].titleWidth + spacing
            guard cost <= remaining else { break }
            shown.insert(index)
            remaining -= cost
        }
        return LeoAgentPaneTabLayout(entries: tabs.enumerated().map {
            Entry(id: $0.element.id, presentation: shown.contains($0.offset) ? .titleOnly : .overflow)
        })
    }
}
