import AppKit
import SwiftUI

/// The ordered environment list editor (B-283), shared by the spawn sheet
/// and Edit Order…: drag to reorder, "+" adds a configured name (offered
/// alphabetically), ⌫ or "−" removes the selected one, ⌥⌘↑/↓ move it.
/// Names only; values never reach the app.
struct LeoEnvironmentListEditor: View {
    @Binding var list: LeoEnvironmentList
    /// The catalog's names.
    let available: [String]
    /// What an empty list means, shown in its place.
    var emptyText = "Template default"
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: $selection) {
                ForEach(list.names, id: \.self) { name in
                    Text(name).tag(name)
                }
                .onMove { list = list.moving(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 104)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if list.names.isEmpty {
                    Text(emptyText).font(.callout).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Environments, in order")
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            let addable = list.addable(from: available)
            Menu {
                ForEach(addable, id: \.self) { name in
                    Button(name) { list = list.adding(name) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(addable.isEmpty)
            .help("Add Environment")
            .accessibilityLabel("Add Environment")
            Button(action: removeSelected) { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Remove Environment")
                .accessibilityLabel("Remove Environment")
            Spacer()
            Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(selection == nil || selection == list.names.first)
                .help("Move Up (⌥⌘↑)")
                .accessibilityLabel("Move Up")
            Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(selection == nil || selection == list.names.last)
                .help("Move Down (⌥⌘↓)")
                .accessibilityLabel("Move Down")
        }
        .buttonStyle(.borderless)
    }

    private func removeSelected() {
        guard let selection else { return }
        list = list.removing(selection)
        self.selection = nil
    }

    private func move(by offset: Int) {
        guard let selection else { return }
        list = list.moving(selection, by: offset)
    }
}

/// Edit Order… for a live agent: the same editor, prefilled with the
/// effective names. Its "Restart and Resume" button is the confirmation.
/// It never dismisses itself: `LeoEnvironmentsSheetSession` owns the sheet.
struct LeoEnvironmentsSheet: View {
    let row: LeoAgentRow
    @ObservedObject var actions: LeoAgentActions
    let onCancel: () -> Void
    let onConfirm: ([String]) -> Void
    private let initial: LeoEnvironmentList
    @State private var list: LeoEnvironmentList

    init(row: LeoAgentRow, actions: LeoAgentActions, onCancel: @escaping () -> Void, onConfirm: @escaping ([String]) -> Void) {
        self.row = row
        self.actions = actions
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        initial = LeoEnvironmentList(row.environments?.names ?? [])
        _list = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Environments for \(row.name)").font(.headline)
                Text("Applied in this order. Changing them restarts \(row.name) and resumes its session.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LeoEnvironmentListEditor(list: $list, available: actions.environmentCatalog.catalog?.names ?? [])
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(LeoEnvironmentConfirmation(agent: row.name, names: list.names).confirmTitle) { onConfirm(list.names) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(list == initial)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// A sheet window whose Escape (`cancelOperation`) goes to its owner.
final class LeoSheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// One Edit Order… sheet, owned for its whole life: begun on the parent
/// window with `beginSheet` (no content view controller needed, so it works
/// on terminal windows), kept alive in `live` until AppKit's completion
/// handler, and ended by Cancel, Escape or Restart and Resume alike.
@MainActor final class LeoEnvironmentsSheetSession {
    private static var live: [ObjectIdentifier: LeoEnvironmentsSheetSession] = [:]

    let sheetWindow: LeoSheetWindow
    private weak var parent: NSWindow?
    private let row: LeoAgentRow
    private let actions: LeoAgentActions
    private var isFinished = false

    private init(row: LeoAgentRow, actions: LeoAgentActions, parent: NSWindow) {
        self.row = row
        self.actions = actions
        self.parent = parent
        sheetWindow = LeoSheetWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheetWindow.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LeoEnvironmentsSheet(
            row: row, actions: actions,
            onCancel: { [weak self] in self?.cancel() },
            onConfirm: { [weak self] in self?.confirm($0) }
        ))
        sheetWindow.contentViewController = hosting
        sheetWindow.setContentSize(hosting.view.fittingSize)
        sheetWindow.onCancel = { [weak self] in self?.cancel() }
    }

    /// Nil when `window` already has a sheet up.
    @discardableResult
    static func present(_ row: LeoAgentRow, actions: LeoAgentActions, on window: NSWindow) -> LeoEnvironmentsSheetSession? {
        guard window.attachedSheet == nil else { return nil }
        let session = LeoEnvironmentsSheetSession(row: row, actions: actions, parent: window)
        let key = ObjectIdentifier(session)
        live[key] = session
        window.beginSheet(session.sheetWindow) { _ in live[key] = nil }
        return session
    }

    func cancel() { finish() }

    func confirm(_ names: [String]) {
        guard !isFinished else { return }
        actions.setEnvironments(row, names: names)
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        if let parent { parent.endSheet(sheetWindow) } else { sheetWindow.close() }
    }
}

/// Presents the environment change UI for both entry points (the row's
/// context menu and the Agent menu), so they can't drift apart.
@MainActor enum LeoEnvironmentChange {
    /// Asks first (the agent restarts), then sets `names`.
    static func confirm(_ row: LeoAgentRow, names: [String], actions: LeoAgentActions, window: NSWindow? = NSApp.keyWindow) {
        let confirmation = LeoEnvironmentConfirmation(agent: row.name, names: names)
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let apply = { actions.setEnvironments(row, names: names) }
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { apply() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }

    /// One submenu item's action.
    static func perform(_ entry: LeoEnvironmentMenuEntry, row: LeoAgentRow, actions: LeoAgentActions, window: NSWindow? = NSApp.keyWindow) {
        switch entry {
        case .toggle(let name, _):
            confirm(row, names: LeoEnvironmentList(row.environments?.names ?? []).toggling(name).names, actions: actions, window: window)
        case .reset:
            confirm(row, names: [], actions: actions, window: window)
        case .editOrder:
            guard let window else { return }
            LeoEnvironmentsSheetSession.present(row, actions: actions, on: window)
        case .placeholder, .separator:
            break
        }
    }
}
