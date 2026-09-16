import Foundation

/// Owns a DRAFT `[LeoHostConfiguration]` copied from `LeoHostStore.load()`
/// on creation. Every edit (add/remove/field change) mutates only the
/// draft; nothing touches the store until `save()`. Cancel = just discard
/// this model without calling `save()`.
@MainActor final class LeoHostsSheetModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var hosts: [LeoHostConfiguration]
    @Published var selectedID: LeoHostConfiguration.ID?
    @Published private(set) var saveError: String?

    private let store: LeoHostStore
    private let onSaved: () -> Void

    init(store: LeoHostStore, onSaved: @escaping () -> Void = {}) {
        self.store = store
        self.onSaved = onSaved
        let loaded = store.load()
        hosts = loaded
        selectedID = loaded.first?.id
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

    /// `LeoHostConfiguration`'s fields are all `let` (immutable, per project
    /// style) -- editing means replacing the selected element with a new
    /// value built from it, never mutating in place.
    func updateSelected(_ transform: (LeoHostConfiguration) -> LeoHostConfiguration) {
        guard let index = selectedIndex else { return }
        hosts[index] = transform(hosts[index])
    }

    /// Live validation messages for `host`: `LeoHostConfiguration.validate()`
    /// plus a duplicate-name check across the current draft (the store's
    /// own duplicate check only fires at `save()` time; this drives the
    /// Save button's disabled state and inline messages before that).
    func errors(for host: LeoHostConfiguration) -> [String] {
        var messages = host.validate().map(\.leoHostsSheetMessage)
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
        do {
            try store.save(hosts)
            hosts = store.load()
            selectedID = selectedID.flatMap { id in hosts.first { $0.id == id }?.id } ?? hosts.first?.id
            saveError = nil
            onSaved()
            return true
        } catch {
            saveError = Self.message(for: error)
            return false
        }
    }

    private func isDuplicateName(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return hosts.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.count > 1
    }

    private func uniqueName() -> String {
        var candidate = "New Host"
        var suffix = 2
        while hosts.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "New Host \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func message(for error: Error) -> String {
        switch error {
        case LeoHostStoreError.invalidConfiguration(let name, let errors):
            return "\(name): " + errors.map(\.leoHostsSheetMessage).joined(separator: ", ")
        case LeoHostStoreError.duplicateName(let name):
            return "A host named \"\(name)\" already exists"
        default:
            return error.localizedDescription
        }
    }
}

extension LeoHostValidationError {
    var leoHostsSheetMessage: String {
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
