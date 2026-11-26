import Foundation
import os

/// `leo.credentials.add("api-key", {provider})`: the user pastes a key into
/// Leo's own sheet, Leo keeps it in the Keychain, and the plugin gets a handle.
/// The key is never sent across the bridge, logged or written to the registry.
extension LeoPluginBridgeRouter {
    func addAPIKey(id: String, provider: String?, ref: String?) {
        let services: LeoPluginCredentialServices
        let vault: LeoPluginAPIKeyVault
        let declared: LeoPluginAPIKeyProvider
        do {
            services = try requireCredentials()
            vault = try Self.vault(services)
            guard let provider, let approved = deps.engine.apiKeyProvider(provider) else {
                throw LeoPluginCredentialRefusal.permissionDenied("unknown or unapproved api-key provider")
            }
            declared = approved
            try spendGesture(ref)
        } catch {
            return deps.send(.reply(id: id, outcome: .rejected(reason: error.localizedDescription)))
        }
        let pluginID = deps.identity.id
        let pluginName = deps.identity.name
        replyLater(id) {
            guard let entry = await services.picker.pickAPIKey(for: declared, pluginName: pluginName) else { return .null }
            let grant = try await Self.savedKeyGrant(entry, provider: declared, pluginID: pluginID, services: services, vault: vault)
            return Self.value(grant, home: services.home)
        }
    }

    /// Saves the key, then the grant that names it. If the grant can't be saved
    /// the key is deleted again, so no orphan is left behind.
    private static func savedKeyGrant(
        _ entry: LeoPluginAPIKeyEntry, provider: LeoPluginAPIKeyProvider, pluginID: String, services: LeoPluginCredentialServices,
        vault: LeoPluginAPIKeyVault
    ) async throws -> LeoPluginCredentialGrant {
        guard let key = LeoPluginAPIKeyVault.normalize(entry.key) else { throw LeoPluginCredentialRefusal.invalidKey }
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? provider.label : trimmed
        guard LeoPluginCredentialGrant.isValidAPIKeyName(name) else {
            throw LeoPluginCredentialRefusal.permissionDenied("the key's name must be 1–\(LeoPluginCredentialGrant.maxAPIKeyNameLength) characters")
        }
        let grantID = UUID().uuidString
        try await offMain { () throws(LeoPluginAPIKeyVaultError) in try vault.save(key, pluginID: pluginID, grantID: grantID) }
        let grant: LeoPluginCredentialGrant?
        do {
            grant = try services.grants.addAPIKeyGrant(pluginID: pluginID, provider: provider.provider, name: name, id: grantID)
        } catch {
            grant = nil
        }
        guard let grant else {
            try? await offMain { () throws(LeoPluginAPIKeyVaultError) in try vault.delete(pluginID: pluginID, grantID: grantID) }
            throw LeoPluginCredentialRefusal.permissionDenied("the key couldn't be saved")
        }
        return grant
    }

    /// Deletes a removed grant's key. A failure leaves an orphan item that the
    /// uninstall sweep removes; the grant itself is already gone.
    func deleteKey(grantID: String, services: LeoPluginCredentialServices) {
        do {
            try services.apiKeys?.delete(pluginID: deps.identity.id, grantID: grantID)
        } catch {
            LeoLog.logger(category: "leo.plugins").warning(
                "couldn't delete the API key item for \(self.deps.identity.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    static func vault(_ services: LeoPluginCredentialServices) throws -> LeoPluginAPIKeyVault {
        guard let vault = services.apiKeys else { throw LeoPluginCredentialRefusal.permissionDenied("API keys are unavailable") }
        return vault
    }

    /// Reads a key on a background thread: a read with UI blocks on the dialog.
    static func readKeyOffMain(
        _ vault: LeoPluginAPIKeyVault, pluginID: String, grantID: String, host: String, allowUI: Bool
    ) async throws -> LeoPluginFetchCredential {
        let result = await Task.detached { () -> Result<LeoPluginFetchCredential, LeoPluginCredentialError> in
            do throws(LeoPluginCredentialError) {
                return .success(try vault.credential(pluginID: pluginID, grantID: grantID, host: host, allowUI: allowUI))
            } catch {
                return .failure(error)
            }
        }.value
        return try result.mapError(LeoPluginCredentialRefusal.unreadable).get()
    }

    /// Runs a Keychain write on a background thread; a refusal becomes a plugin-facing reason.
    private static func offMain(_ body: @escaping @Sendable () throws(LeoPluginAPIKeyVaultError) -> Void) async throws {
        let failure = await Task.detached { () -> LeoPluginAPIKeyVaultError? in
            do throws(LeoPluginAPIKeyVaultError) {
                try body()
                return nil
            } catch {
                return error
            }
        }.value
        switch failure {
        case nil: return
        case .invalidKey?: throw LeoPluginCredentialRefusal.invalidKey
        case .invalidAccount?, .keychain?: throw LeoPluginCredentialRefusal.permissionDenied("the key couldn't be saved to the Keychain")
        }
    }
}
