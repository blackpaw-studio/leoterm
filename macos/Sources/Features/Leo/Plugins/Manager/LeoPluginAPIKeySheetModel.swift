import Foundation
import LeoKit

/// The Add API Key sheet's state: the pasted key and an optional name. The key
/// is checked here so Add is only enabled for one Leo will accept; it is
/// handed out once, as an entry, and never echoed in any message.
@MainActor final class LeoPluginAPIKeySheetModel: ObservableObject {
    let provider: LeoPluginAPIKeyProvider
    let pluginName: String
    @Published var key = ""
    /// Starts as the provider's label; a blank name falls back to it.
    @Published var name: String

    init(provider: LeoPluginAPIKeyProvider, pluginName: String) {
        self.provider = provider
        self.pluginName = pluginName
        name = provider.label
    }

    /// "<Plugin> wants an API key for <label>. It will only be sent to <host>."
    var message: String {
        "\(pluginName) wants an API key for \(provider.label). It will only be sent to \(provider.host)."
    }

    /// Why the pasted key can't be used; nil while it is empty or when it is fine.
    var keyProblem: String? {
        guard !trimmedKey.isEmpty, LeoPluginAPIKeyVault.normalize(key) == nil else { return nil }
        if trimmedKey.utf8.count > LeoPluginAPIKeyVault.maxKeyBytes {
            return "That key is too long (at most \(LeoPluginAPIKeyVault.maxKeyBytes) characters)."
        }
        return "That doesn't look like an API key: it should be letters, digits and symbols, with no spaces."
    }

    var nameProblem: String? {
        LeoPluginCredentialGrant.isValidAPIKeyName(resolvedName)
            ? nil : "Use a name of up to \(LeoPluginCredentialGrant.maxAPIKeyNameLength) characters."
    }

    var canAdd: Bool { LeoPluginAPIKeyVault.normalize(key) != nil && nameProblem == nil }

    /// The key and name to save, or nil unless Add is enabled.
    func entry() -> LeoPluginAPIKeyEntry? {
        guard canAdd, let normalized = LeoPluginAPIKeyVault.normalize(key) else { return nil }
        return LeoPluginAPIKeyEntry(key: normalized, name: resolvedName)
    }

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.label : trimmed
    }
}
