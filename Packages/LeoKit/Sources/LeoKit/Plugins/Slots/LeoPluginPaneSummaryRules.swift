import Foundation

/// What a pane's one-line summary may show: `Text`, `Meter` and `Accessory`,
/// laid out in a single row. Anything else would need more room than the
/// collapsed tab bar has, so the slot is put in an error state instead.
public enum LeoPluginPaneSummaryRules {
    /// The first reason `root` can't be a summary, or nil when it can.
    public static func violation(in root: LeoPluginSlotRoot) -> String? {
        guard let bad = root.nodes.first(where: { !isAllowed($0) }) else { return nil }
        return "A pane summary can only show Text, Meter and Accessory, not \(typeName(bad))."
    }

    private static func isAllowed(_ node: LeoPluginNode) -> Bool {
        switch node {
        case .text, .meter, .accessory: true
        case .list, .detail, .form, .emptyState, .loading, .error: false
        }
    }

    private static func typeName(_ node: LeoPluginNode) -> String {
        switch node {
        case .list: "List"
        case .detail: "Detail"
        case .form: "Form"
        case .accessory: "Accessory"
        case .text: "Text"
        case .meter: "Meter"
        case .emptyState: "EmptyState"
        case .loading: "Loading"
        case .error: "Error"
        }
    }
}
