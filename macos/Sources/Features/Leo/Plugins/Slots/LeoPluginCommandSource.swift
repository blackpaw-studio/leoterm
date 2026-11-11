import LeoKit

/// A plugin command as the palette lists it.
struct LeoPluginPaletteCommand: Identifiable, Equatable {
    let pluginID: String
    let pluginName: String
    let commandID: String
    let title: String
    let sfSymbol: String?

    var id: String { "\(pluginID)\u{1F}\(commandID)" }
    var slotKey: LeoPluginSlotKey { LeoPluginSlotKey(pluginID: pluginID, slot: .palette(commandID: commandID)) }
}

/// What the upstream command palette is given to list plugin commands. Kept
/// behind a protocol so the palette's diff stays small and tests need no manager.
@MainActor protocol LeoPluginCommandSource: AnyObject {
    var commands: [LeoPluginPaletteCommand] { get }
    /// Sends the plugin `command(id)`; the returned session is the page the
    /// palette shows while it answers.
    func select(_ command: LeoPluginPaletteCommand) -> LeoPluginPaletteSession
}

@MainActor final class LeoPluginManagerCommandSource: LeoPluginCommandSource {
    private let host: any LeoPluginSlotHosting

    init(host: any LeoPluginSlotHosting) { self.host = host }

    var commands: [LeoPluginPaletteCommand] {
        host.plugins.filter(\.isEnabled).flatMap { info -> [LeoPluginPaletteCommand] in
            (info.manifest?.contributes.commands ?? []).map {
                LeoPluginPaletteCommand(pluginID: info.id, pluginName: info.name, commandID: $0.id, title: $0.title, sfSymbol: $0.sfSymbol)
            }
        }
    }

    func select(_ command: LeoPluginPaletteCommand) -> LeoPluginPaletteSession {
        host.open(command.slotKey.slot, plugin: command.pluginID)
        return LeoPluginPaletteSession(command: command, binding: LeoPluginSlotBinding(host: host, key: command.slotKey))
    }
}

/// The palette's page for one selected command: its slot's content, with
/// `pushView` stacking over it and Esc popping.
@MainActor final class LeoPluginPaletteSession: ObservableObject {
    enum Back: Equatable {
        /// A pushed view was removed; the page stays.
        case popped
        /// Nothing was pushed: the palette returns to its command list.
        case atRoot
    }

    let command: LeoPluginPaletteCommand
    let binding: LeoPluginSlotBinding

    init(command: LeoPluginPaletteCommand, binding: LeoPluginSlotBinding) {
        self.command = command
        self.binding = binding
    }

    var nodes: [LeoPluginNode] { binding.nodes }

    func back() -> Back { binding.popPushed() ? .popped : .atRoot }

    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?) { binding.perform(action, gesture: gesture) }
}
