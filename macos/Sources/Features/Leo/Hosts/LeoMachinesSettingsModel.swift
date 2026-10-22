import Foundation
import LeoKit

/// Owns a DRAFT `[LeoHostConfiguration]` copied from `LeoHostStore.load()`
/// on creation. Every edit (add/remove/enable/field change) mutates only the
/// draft; nothing touches the store until `save()`, and `revert()` takes the
/// draft back to the store. `onSaved` (the registry's `reload()`) is the
/// model's only way to reach live connections, and it fires on a successful
/// Save alone: Test Connection runs on its own throwaway connection.
@MainActor final class LeoMachinesSettingsModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var hosts: [LeoHostConfiguration]
    @Published var selectedID: LeoHostConfiguration.ID? {
        didSet { if selectedID != oldValue { invalidateTest() } }
    }
    @Published private(set) var saveError: String?
    /// The latest Test Connection result for the selected draft; nil while
    /// untested, while a test runs, and after any edit that could change it.
    @Published private(set) var testReport: LeoConnectionTestReport?
    @Published private(set) var isTesting = false

    private let store: LeoHostStore
    private let tester: any LeoMachineConnectionTesting
    private let onSaved: () -> Void
    private var testGeneration = 0
    /// The store's contents at the moment this model opened. Two Hosts
    /// editor windows can independently open drafts from the same store;
    /// without this, the later `save()` would blindly overwrite whatever
    /// the earlier window already saved (silently resurrecting a host the
    /// earlier window removed, or discarding its edits). `save()` refuses
    /// instead of writing if the store no longer matches this snapshot.
    private var openedSnapshot: [LeoHostConfiguration]

    init(store: LeoHostStore, tester: any LeoMachineConnectionTesting, onSaved: @escaping () -> Void = {}) {
        self.store = store
        self.tester = tester
        self.onSaved = onSaved
        let loaded = store.load()
        hosts = loaded
        selectedID = loaded.first?.id
        openedSnapshot = loaded
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return hosts.firstIndex { $0.id == selectedID }
    }

    var selectedHost: LeoHostConfiguration? {
        selectedIndex.map { hosts[$0] }
    }

    func addHost() {
        let host = LeoHostConfiguration(name: uniqueName(), sshTarget: "")
        hosts.append(host)
        selectedID = host.id
    }

    func removeSelected() {
        guard let index = selectedIndex else { return }
        hosts.remove(at: index)
        selectedID = hosts.first?.id
    }

    /// Whether the draft differs from what is saved.
    var isDirty: Bool { hosts != openedSnapshot }

    /// The list's toggle: a disabled machine stays configured but is never
    /// connected once saved.
    func setEnabled(_ isEnabled: Bool, for id: LeoHostConfiguration.ID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index] = hosts[index].replacing(isEnabled: isEnabled)
    }

    /// Drops every unsaved change and re-reads the store, adopting anything
    /// another window saved since this one opened.
    func revert() {
        let loaded = store.load()
        hosts = loaded
        openedSnapshot = loaded
        selectedID = selectedID.flatMap { id in loaded.first { $0.id == id }?.id } ?? loaded.first?.id
        saveError = nil
        invalidateTest()
    }

    /// Runs Test Connection on the selected draft, saved or not. A result
    /// that arrives after the selection or the draft changed is dropped.
    func testSelected() async {
        guard let host = selectedHost, host.validate().isEmpty else { return }
        invalidateTest()
        let generation = testGeneration
        isTesting = true
        let report = await tester.test(host)
        guard generation == testGeneration else { return }
        isTesting = false
        testReport = report
    }

    private func invalidateTest() {
        testGeneration += 1
        testReport = nil
        isTesting = false
    }

    /// `LeoHostConfiguration`'s fields are all `let` (immutable, per project
    /// style) -- editing means replacing the selected element with a new
    /// value built from it, never mutating in place.
    func updateSelected(_ transform: (LeoHostConfiguration) -> LeoHostConfiguration) {
        guard let index = selectedIndex else { return }
        let updated = transform(hosts[index])
        guard updated != hosts[index] else { return }
        hosts[index] = updated
        invalidateTest()
    }

    /// Live validation messages for `host`: `LeoHostConfiguration.validate()`
    /// plus a duplicate-name check across the current draft (the store's
    /// own duplicate check only fires at `save()` time; this drives the
    /// Save button's disabled state and inline messages before that).
    func errors(for host: LeoHostConfiguration) -> [String] {
        var messages = host.validate().map(\.leoMachinesSettingsMessage)
        if isDuplicateName(host.name) {
            messages.append("A host named \"\(host.name)\" already exists")
        }
        return messages
    }

    var isValid: Bool {
        hosts.allSatisfy { errors(for: $0).isEmpty }
    }

    /// The Save button is disabled while `!isValid` (live validation), but
    /// `save()` itself always attempts the write and surfaces whatever the
    /// store's own validation says -- belt and suspenders, and keeps the
    /// store the single source of truth for what's actually persistable.
    @discardableResult
    func save() -> Bool {
        guard store.load() == openedSnapshot else {
            saveError = "Hosts changed in another window; reopen to edit"
            return false
        }
        do {
            try store.save(hosts.map(Self.normalizingEmptyPathsToDefaults))
            hosts = store.load()
            openedSnapshot = hosts
            selectedID = selectedID.flatMap { id in hosts.first { $0.id == id }?.id } ?? hosts.first?.id
            saveError = nil
            onSaved()
            return true
        } catch {
            saveError = Self.message(for: error)
            return false
        }
    }

    /// Clearing the remote leo/socket path fields must not instantly snap
    /// back to the placeholder default while the user is still typing --
    /// the draft keeps whatever (possibly empty) text they typed, and only
    /// `save()` normalizes an empty value to the default.
    private static func normalizingEmptyPathsToDefaults(_ host: LeoHostConfiguration) -> LeoHostConfiguration {
        LeoHostConfiguration(
            id: host.id,
            name: host.name,
            sshTarget: host.sshTarget,
            identityFile: host.identityFile,
            remoteLeoPath: host.remoteLeoPath.isEmpty ? "~/.local/bin/leo" : host.remoteLeoPath,
            remoteSocketPath: host.remoteSocketPath.isEmpty ? "~/.leo/state/leo.sock" : host.remoteSocketPath,
            isEnabled: host.isEnabled
        )
    }

    private func isDuplicateName(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return hosts.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.count > 1
    }

    private func uniqueName() -> String {
        var candidate = "New Machine"
        var suffix = 2
        while hosts.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "New Machine \(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func message(for error: Error) -> String {
        // Host names are left as is: the user typed them in this sheet.
        switch error {
        case LeoHostStoreError.invalidConfiguration(let name, let errors):
            return "\(name): " + errors.map(\.leoMachinesSettingsMessage).joined(separator: ", ")
        case LeoHostStoreError.duplicateName(let name):
            return "A host named \"\(name)\" already exists"
        default:
            // Untrusted: one line, isolated in its own direction.
            return LeoSFTPServerText.isolated(error.localizedDescription)
        }
    }
}

extension LeoHostValidationError {
    var leoMachinesSettingsMessage: String {
        switch self {
        case .emptyName: "Name is required"
        case .reservedName: "\"localhost\" is reserved"
        case .emptySSHTarget: "SSH target is required"
        case .malformedPort: "Port must be between 1 and 65535"
        case .invalidName: "Name cannot contain \"/\" or a NUL character"
        case .unsafeSSHTarget: "SSH target contains unsafe characters"
        case .unsafeIdentityFile: "Identity file path cannot start with \"-\""
        case .ipv6NotSupported: "IPv6 addresses are not supported; use a hostname"
        }
    }
}

extension LeoHostConfiguration {
    /// A copy with the given fields replaced. `identityFile` is doubly
    /// optional: nil keeps it, `.some(nil)` clears it.
    func replacing(
        name: String? = nil, sshTarget: String? = nil, identityFile: String?? = nil,
        remoteLeoPath: String? = nil, remoteSocketPath: String? = nil, isEnabled: Bool? = nil
    ) -> LeoHostConfiguration {
        LeoHostConfiguration(
            id: id,
            name: name ?? self.name,
            sshTarget: sshTarget ?? self.sshTarget,
            identityFile: identityFile ?? self.identityFile,
            remoteLeoPath: remoteLeoPath ?? self.remoteLeoPath,
            remoteSocketPath: remoteSocketPath ?? self.remoteSocketPath,
            isEnabled: isEnabled ?? self.isEnabled
        )
    }
}
