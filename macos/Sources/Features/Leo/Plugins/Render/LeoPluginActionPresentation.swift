import Foundation
import LeoKit

/// One row of a context menu or action panel.
struct LeoPluginActionEntry: Equatable {
    let index: Int
    let title: String
    let sfSymbol: String
    let action: LeoPluginAction
}

/// The menu text and symbol are the plugin's own `title` / `sfSymbol` when it
/// gave them, else derived from the action kind. Callback ids are humanised
/// ("merge-pr" → "Merge Pr").
enum LeoPluginActionPresentation {
    static func entries(for actions: [LeoPluginLabeledAction]) -> [LeoPluginActionEntry] {
        actions.enumerated().map { index, labeled in
            LeoPluginActionEntry(
                index: index, title: nonBlank(labeled.title) ?? title(for: labeled.action),
                sfSymbol: nonBlank(labeled.sfSymbol) ?? symbol(for: labeled.action), action: labeled.action)
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func title(for action: LeoPluginAction) -> String {
        switch action {
        case .callback(let id, _): humanised(id)
        case .pushView: "Open"
        case .openURL: "Open in Browser"
        case .copy: "Copy"
        case .sendToAgent(let agent, _): "Send to \(agent.name)…"
        case .spawnAgent: "Spawn Agent…"
        }
    }

    static func symbol(for action: LeoPluginAction) -> String {
        switch action {
        case .callback: "bolt"
        case .pushView: "chevron.right"
        case .openURL: "safari"
        case .copy: "doc.on.doc"
        case .sendToAgent: "paperplane"
        case .spawnAgent: "plus.rectangle.on.rectangle"
        }
    }

    private static func humanised(_ id: String) -> String {
        let words = id.split { "-_. ".contains($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? "Run" : words.joined(separator: " ")
    }
}
