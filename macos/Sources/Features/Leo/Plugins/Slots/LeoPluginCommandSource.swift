import Combine
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
    private let surface: any LeoPluginSlotSurface

    init(host: any LeoPluginSlotHosting, surface: any LeoPluginSlotSurface) {
        self.host = host
        self.surface = surface
    }

    var commands: [LeoPluginPaletteCommand] {
        host.plugins.filter(\.isEnabled).flatMap { info -> [LeoPluginPaletteCommand] in
            (info.manifest?.contributes.commands ?? []).map {
                LeoPluginPaletteCommand(pluginID: info.id, pluginName: info.name, commandID: $0.id, title: $0.title, sfSymbol: $0.sfSymbol)
            }
        }
    }

    func select(_ command: LeoPluginPaletteCommand) -> LeoPluginPaletteSession {
        host.open(command.slotKey.slot, plugin: command.pluginID)
        return LeoPluginPaletteSession(command: command, host: host, surface: surface)
    }
}

/// The palette's page for one selected command: its slot, with `pushView`
/// stacking over it and Esc popping. The slot is drawn by the shared host view.
@MainActor final class LeoPluginPaletteSession: ObservableObject {
    enum Back: Equatable {
        /// A pushed view was removed; the page stays.
        case popped
        /// Nothing was pushed: the palette returns to its command list.
        case atRoot
    }

    let command: LeoPluginPaletteCommand
    let surface: any LeoPluginSlotSurface
    private let host: any LeoPluginSlotHosting
    private var subscription: AnyCancellable?

    /// The command's handler finished without rendering its page, so there is
    /// nothing to show: the palette closes instead of sitting on Loading.
    var onFinishedWithoutRender: () -> Void = {}

    var key: LeoPluginSlotKey { command.slotKey }

    init(command: LeoPluginPaletteCommand, host: any LeoPluginSlotHosting, surface: any LeoPluginSlotSurface) {
        self.command = command
        self.host = host
        self.surface = surface
        let key = command.slotKey
        subscription = host.commandFinishedWithoutRender
            .filter { $0 == key }
            .sink { [weak self] _ in self?.onFinishedWithoutRender() }
    }

    func back() -> Back {
        guard host.slots.pushed[key]?.isEmpty == false else { return .atRoot }
        surface.pop(key)
        return .popped
    }
}
