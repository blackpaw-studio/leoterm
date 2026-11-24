import AppKit
import LeoKit

/// The folder chooser behind `leo.credentials.add`: the user picks which CLI
/// config folder (and so which account) a plugin may use. Directories only,
/// hidden files shown (config folders start with a dot), starting at home.
/// Non-modal, like the browser's file chooser: it never freezes a window.
@MainActor struct LeoPluginCredentialPicker: LeoPluginCredentialPicking {
    let home: URL
    /// Connected machines other than this Mac, and the live daemon for each.
    let remoteMachines: @MainActor () -> [LeoHostID]
    let daemon: @MainActor (LeoHostID) -> (any LeoDaemonClient)?
    var presenter = LeoPluginSheetPresenter()

    /// With no other machine connected there is nothing to choose between,
    /// so it goes straight to the folder panel. Otherwise a small sheet asks which machine first.
    func pickAccount(for kind: LeoPluginCredentialKind) async -> LeoPluginCredentialSelection? {
        let remotes = remoteMachines()
        guard !remotes.isEmpty else { return await pickFolder(for: kind).map { LeoPluginCredentialSelection(machine: .local, path: $0) } }
        let model = LeoPluginAccountPickerModel(kind: kind, machines: [.local] + remotes, daemon: { daemon($0) })
        let choice = await presenter.presentCancellable { finish in LeoPluginAccountSheet(model: model, finish: finish) }
        switch choice {
        case nil: return nil
        case .thisMac?: return await pickFolder(for: kind).map { LeoPluginCredentialSelection(machine: .local, path: $0) }
        case .remote(let host, let dir)?: return LeoPluginCredentialSelection(machine: host, path: dir)
        }
    }

    func pickFolder(for kind: LeoPluginCredentialKind) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = home
        panel.prompt = "Use Account"
        panel.message = Self.message(for: kind)
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url?.path : nil)
            }
        }
    }

    static func message(for kind: LeoPluginCredentialKind) -> String {
        let example = switch kind {
        case .claudeCode: "~/.claude"
        case .codex: "~/.codex"
        }
        return "Choose the \(kind.displayName) folder for the account to use, such as \(example). Leo reads its sign-in; the plugin never sees it."
    }
}
