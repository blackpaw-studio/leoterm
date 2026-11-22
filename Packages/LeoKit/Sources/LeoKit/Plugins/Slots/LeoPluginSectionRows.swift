import Foundation

/// What a sidebar section draws for its slot's components: flat rows that
/// flow with the sidebar's own scrolling, like the Terminals section's. A list
/// becomes its items (its section titles only when there are several: a lone
/// title would repeat the section's own header); an empty state or a detail is
/// one line of text. Components a sidebar can't host (forms, accessories) draw
/// nothing. Pure, so the rules are tested without a view.
public enum LeoPluginSectionRows {
    public enum Row: Equatable, Sendable, Identifiable {
        case subheader(id: String, title: String)
        case item(id: String, LeoPluginNode.Item)
        case message(id: String, title: String, detail: String?)
        case group(id: String, LeoPluginNode.Group)
        case meter(id: String, LeoPluginNode.ValueMeter)

        public var id: String {
            switch self {
            case .subheader(let id, _), .item(let id, _), .message(let id, _, _), .group(let id, _), .meter(let id, _): id
            }
        }
    }

    /// A section's header extra and its body rows.
    public struct Layout: Equatable, Sendable {
        /// A root that starts with an Accessory has it drawn at the header's
        /// trailing edge (shown even when the section is collapsed), not in the body.
        public let headerAccessory: LeoPluginNode.Accessory?
        public let rows: [Row]
    }

    public static let emptyTitle = "Nothing to show"

    public static func layout(from nodes: [LeoPluginNode]) -> Layout {
        let header: LeoPluginNode.Accessory? = if case .accessory(let accessory)? = nodes.first { accessory } else { nil }
        let body = nodes.enumerated().dropFirst(header == nil ? 0 : 1)
        let all = body.flatMap { index, node in rows(for: node, at: index) }
        return Layout(headerAccessory: header, rows: all.isEmpty ? [.message(id: "empty", title: emptyTitle, detail: nil)] : all)
    }

    public static func make(from nodes: [LeoPluginNode]) -> [Row] { layout(from: nodes).rows }

    private static func rows(for node: LeoPluginNode, at index: Int) -> [Row] {
        switch node {
        case .list(let list):
            let showsTitles = list.sections.count > 1
            return list.sections.enumerated().flatMap { sectionIndex, section -> [Row] in
                let header: [Row] = showsTitles ? section.title.map { [.subheader(id: "h\(index).\(sectionIndex)", title: $0)] } ?? [] : []
                return header + section.items.map { .item(id: "\(index).\(sectionIndex).\($0.id)", $0) }
            }
        case .emptyState(let state):
            return [.message(id: "n\(index)", title: state.title, detail: state.message)]
        case .detail(let detail):
            return plainFirstLine(detail.markdown).map { [.message(id: "n\(index)", title: $0, detail: nil)] } ?? []
        case .error(let state):
            return [.message(id: "n\(index)", title: state.message, detail: nil)]
        case .loading(let loading):
            return [.message(id: "n\(index)", title: loading.message ?? "Loading…", detail: nil)]
        case .text(let text):
            return [.message(id: "n\(index)", title: text.plainText, detail: nil)]
        case .group(let group):
            return [.group(id: "g\(index)", group)]
        case .valueMeter(let meter):
            return [.meter(id: "m\(index)", meter)]
        case .form, .accessory, .meter:
            return []
        }
    }

    private static func plainFirstLine(_ markdown: String) -> String? {
        let line = markdown.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        let stripped = line.drop { "#-*> ".contains($0) }.filter { !"*_`".contains($0) }
        return stripped.isEmpty ? nil : String(stripped)
    }
}
