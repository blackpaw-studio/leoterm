import AppKit
import SwiftUI

/// One caption line of height with nothing to show or announce.
struct LeoReservedCaptionLine: View {
    var body: some View {
        Text(" ").font(.caption).lineLimit(1).hidden().accessibilityHidden(true)
    }
}

/// The row's third line. Always one caption line: each variant is
/// single-line, and `.empty` reserves the same height invisibly. The
/// SF Symbols in the labels are taller than caption text, so every variant
/// is pinned to the caption font's line height -- a tool starting or
/// stopping must not move the rows below it.
struct LeoAgentRowDetailLine: View {
    let details: LeoAgentRowPresentation

    /// The caption font's line height, from the font rather than a constant.
    static var lineHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        return ceil(font.ascender - font.descender + font.leading)
    }

    var body: some View {
        line
            .frame(height: Self.lineHeight, alignment: .leading)
    }

    @ViewBuilder private var line: some View {
        switch details.detail {
        case .compacting(let compacting):
            // B-261: quiet and static -- it explains a pause, it doesn't
            // ask for anything. Fixed copy only.
            Label {
                Text(compacting)
            } icon: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").imageScale(.small).foregroundStyle(.secondary)
            }
            .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(details.compactingHelp ?? compacting)
                .accessibilityLabel(details.compactingHelp ?? compacting)
        case .task(let task):
            Text(task).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(task)
        case .tool(let tool):
            // B-260: the running tool's name, calm and static; the
            // arguments are never shown.
            // The icon is tinted explicitly: a Label's icon otherwise
            // takes the accent color.
            Label {
                Text(tool)
            } icon: {
                Image(systemName: "hammer").imageScale(.small).foregroundStyle(.secondary)
            }
            .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(details.toolHelp ?? "")
                .accessibilityLabel(details.toolSpoken ?? tool)
        case .turnPreview(let preview):
            // B-259: what the agent just did, only while it isn't doing
            // anything else; the tooltip holds what the line cuts.
            Text(preview).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(preview)
        case .empty:
            LeoReservedCaptionLine()
        }
    }
}
