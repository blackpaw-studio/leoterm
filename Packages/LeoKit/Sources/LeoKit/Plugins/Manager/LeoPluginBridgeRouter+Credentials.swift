import Foundation

/// Why the router refused a `leo.credentials` call or a credential fetch.
/// Every reason starts with its code, which plugins match on.
enum LeoPluginCredentialRefusal: Error, Equatable, LocalizedError {
    case permissionDenied(String)
    case gestureRequired
    case unknownCredential
    case unreadable(LeoPluginCredentialError)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let why): "credentialPermissionDenied: \(why)"
        case .gestureRequired: "gestureRequired: this needs a click or key press from the user within the last 30 seconds"
        case .unknownCredential: "unknownCredential: this plugin has no account with that id"
        case .unreadable(.needsAuthorization):
            "\(LeoPluginCredentialError.needsAuthorization.code): Leo needs permission to read this account; call authorize from a click"
        case .unreadable(let error): "\(error.code): the account's sign-in couldn't be read"
        case .invalidKey:
            "credentialInvalid: an API key must be printable ASCII with no spaces, at most \(LeoPluginAPIKeyVault.maxKeyBytes) bytes"
        }
    }
}

/// `leo.credentials` (apiVersion 2). Tokens never cross the bridge: the
/// plugin only ever sees grant handles, and the fetcher injects headers itself.
extension LeoPluginBridgeRouter {
    static let credentialsAPIVersion = 2

    func addCredential(id: String, kind rawKind: String, provider: String?, ref: String?) {
        if rawKind == LeoPluginAPIKeyProvider.kind { return addAPIKey(id: id, provider: provider, ref: ref) }
        let services: LeoPluginCredentialServices
        let kind: LeoPluginCredentialKind
        do {
            services = try requireCredentials()
            guard provider == nil else { throw LeoPluginCredentialRefusal.permissionDenied("provider is only for api-key credentials") }
            kind = try approvedKind(rawKind)
            try spendGesture(ref)
        } catch {
            return deps.send(.reply(id: id, outcome: .rejected(reason: error.localizedDescription)))
        }
        let pluginID = deps.identity.id
        replyLater(id) {
            guard let picked = await services.picker.pickAccount(for: kind) else { return .null }
            let grant = try await Self.checkedGrant(picked, kind: kind, pluginID: pluginID, services: services)
            return Self.value(grant, home: services.home)
        }
    }

    /// Reads the account once now, so a folder without a sign-in is never granted, then saves it.
    /// A remote account is checked by its own machine; nothing is read on this Mac for it.
    private static func checkedGrant(
        _ picked: LeoPluginCredentialSelection, kind: LeoPluginCredentialKind, pluginID: String, services: LeoPluginCredentialServices
    ) async throws -> LeoPluginCredentialGrant {
        let isRemote = picked.machine != .local
        guard !isRemote || picked.path.hasPrefix("/"),
            let path = LeoPluginCredentialPath.standardize(picked.path, home: services.home)
        else { throw LeoPluginCredentialRefusal.unreadable(.invalid) }
        let candidate = LeoPluginCredentialGrant(id: "", kind: kind, path: path, machine: picked.machine)
        if isRemote {
            try await remoteFetcher(kind: kind, path: path, machine: picked.machine, services: services).check()
        } else {
            _ = try await resolveOffMain(candidate, allowUI: true, resolver: services.resolver)
        }
        guard let grant = try services.grants.addGrant(pluginID: pluginID, kind: kind, path: path, machine: picked.machine) else {
            throw LeoPluginCredentialRefusal.permissionDenied("the account couldn't be saved")
        }
        return grant
    }

    static func remoteFetcher(
        kind: LeoPluginCredentialKind, path: String, machine: LeoHostID, services: LeoPluginCredentialServices
    ) -> LeoPluginRemoteCredentialFetcher {
        LeoPluginRemoteCredentialFetcher(host: machine, kind: kind, dir: path, forwarding: services.remote)
    }

    func authorizeCredential(id: String, grantID: String, ref: String?) {
        let grant: LeoPluginCredentialGrant
        let services: LeoPluginCredentialServices
        do {
            (grant, _) = try ownedGrant(grantID)
            services = try requireCredentials()
            try spendGesture(ref)
        } catch {
            return deps.send(.reply(id: id, outcome: .rejected(reason: error.localizedDescription)))
        }
        let pluginID = deps.identity.id
        let approvedHost = { [engine = deps.engine] (provider: String) throws -> String in
            guard let declared = engine.apiKeyProvider(provider) else { throw LeoPluginCredentialRefusal.unknownCredential }
            return declared.host
        }
        replyLater(id) {
            switch grant.subject {
            case .account(let kind, let path) where grant.isRemote:
                // Any dialog is on that machine; all this side can do is ask whether it will act as the account.
                try await Self.remoteFetcher(kind: kind, path: path, machine: grant.machine, services: services).check()
            case .account:
                _ = try await Self.resolveOffMain(grant, allowUI: true, resolver: services.resolver)
            case .apiKey(let provider, _):
                _ = try await Self.readKeyOffMain(
                    try Self.vault(services), pluginID: pluginID, grantID: grant.id, host: try approvedHost(provider), allowUI: true)
            }
            return .null
        }
    }

    func credentialHandles() throws -> LeoJSONValue {
        let services = try requireCredentials()
        let grants = services.grants.grants(pluginID: deps.identity.id).filter { approval(of: $0).isAllowed }
        return .array(grants.map { Self.value($0, home: services.home) })
    }

    func removeCredential(grantID: String) throws -> LeoJSONValue {
        let services = try requireCredentials()
        let (grant, _) = try ownedGrant(grantID)
        if grant.apiKeyProvider != nil { try deleteKey(grantID: grantID, services: services) }
        try services.grants.removeGrant(pluginID: deps.identity.id, grantID: grantID)
        return .null
    }

    /// One of this plugin's own grants, for a kind or provider it is still approved for.
    func ownedGrant(_ grantID: String) throws -> (LeoPluginCredentialGrant, any LeoPluginCredentialResolving) {
        let services = try requireCredentials()
        guard let grant = services.grants.grants(pluginID: deps.identity.id).first(where: { $0.id == grantID }) else {
            throw LeoPluginCredentialRefusal.unknownCredential
        }
        if case .denied(let why) = approval(of: grant) { throw LeoPluginCredentialRefusal.permissionDenied(why) }
        return (grant, services.resolver)
    }

    private func approval(of grant: LeoPluginCredentialGrant) -> LeoPluginPermissionDecision {
        switch grant.subject {
        case .account(let kind, _): deps.engine.check(credential: kind)
        case .apiKey(let provider, _): deps.engine.check(apiKeyProvider: provider)
        }
    }

    /// Reads a token on a background thread: a read with UI blocks on the dialog.
    static func resolveOffMain(
        _ grant: LeoPluginCredentialGrant, allowUI: Bool, resolver: any LeoPluginCredentialResolving
    ) async throws -> LeoPluginFetchCredential {
        let result = await Task.detached { () -> Result<LeoPluginFetchCredential, LeoPluginCredentialError> in
            do throws(LeoPluginCredentialError) {
                return .success(try resolver.resolve(grant, allowUI: allowUI))
            } catch {
                return .failure(error)
            }
        }.value
        return try result.mapError(LeoPluginCredentialRefusal.unreadable).get()
    }

    // MARK: Checks

    func requireCredentials() throws -> LeoPluginCredentialServices {
        guard deps.manifest.apiVersion >= Self.credentialsAPIVersion else {
            throw LeoPluginCredentialRefusal.permissionDenied("leo.credentials needs apiVersion 2")
        }
        guard let services = deps.credentials else {
            throw LeoPluginCredentialRefusal.permissionDenied("accounts are unavailable")
        }
        return services
    }

    private func approvedKind(_ raw: String) throws -> LeoPluginCredentialKind {
        guard let kind = LeoPluginCredentialKind(rawValue: raw) else {
            throw LeoPluginCredentialRefusal.permissionDenied("unknown account kind")
        }
        if case .denied(let why) = deps.engine.check(credential: kind) {
            throw LeoPluginCredentialRefusal.permissionDenied(why)
        }
        return kind
    }

    /// The ref must be a live delivery of this session's, made with a gesture
    /// that hasn't opened a prompt yet. Authority comes from the router's own
    /// record, never from the message.
    func spendGesture(_ ref: String?) throws {
        guard let ref, callbacks.spendCredentialPrompt(ref, now: deps.now()) else {
            throw LeoPluginCredentialRefusal.gestureRequired
        }
    }

    static func value(_ grant: LeoPluginCredentialGrant, home: String) -> LeoJSONValue {
        if let handle = grant.accountHandle(home: home) { return value(handle) }
        guard let handle = grant.apiKeyHandle else { return .null }
        return .object([
            "id": .string(handle.id), "kind": .string(LeoPluginAPIKeyProvider.kind), "provider": .string(handle.provider),
            "name": .string(handle.name),
        ])
    }

    static func value(_ handle: LeoPluginCredentialHandle) -> LeoJSONValue {
        var fields: [String: LeoJSONValue] = [
            "id": .string(handle.id), "kind": .string(handle.kind.rawValue),
            "label": .string(handle.label), "path": .string(handle.path),
        ]
        if let machine = handle.machine { fields["machine"] = .string(machine) }
        return .object(fields)
    }
}
