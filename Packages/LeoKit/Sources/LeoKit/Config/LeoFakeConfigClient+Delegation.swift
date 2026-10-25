import Foundation

extension LeoFakeConfigClient: LeoDelegationAPI {
    public func delegation() async throws -> LeoDelegationDocument {
        calls.append(.delegation)
        try await beforeRead()
        return delegationState?.document(revision: revision) ?? LeoDelegationDocument(revision: revision, configured: false, enabled: false)
    }

    public func delegationPreview(profile: String) async throws -> LeoDelegationPreview {
        calls.append(.delegationPreview(profile))
        try await beforeRead()
        return try requireDelegation().preview(of: profile)
    }

    public func setDelegationCell(profile: String, role: String, target: LeoDelegationTarget, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.cell(profile: profile, role: role, target: target), ifMatch: ifMatch) {
            try $0.setCell(profile: profile, role: role, target: target)
        }
    }

    public func setRoleUseFor(role: String, useFor: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.useFor(role: role, text: useFor), ifMatch: ifMatch) { try $0.setUseFor(role: role, text: useFor) }
    }

    public func setActiveProfile(_ profile: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.active(profile), ifMatch: ifMatch) { try $0.setActive(profile) }
    }

    public func setDelegationEnabled(_ enabled: Bool, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.enabled(enabled), ifMatch: ifMatch) { $0.enabled = enabled }
    }

    public func setHiddenAgents(_ names: [String], ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.hideAgents(names), ifMatch: ifMatch) { $0.hiddenAgents = names }
    }

    public func addDelegationRole(name: String, template: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        let nameError = nameChecker()
        return try await delegationWrite(.addRole(name: name, template: template), ifMatch: ifMatch) {
            try $0.addRole(name: name, template: template, nameError: nameError)
        }
    }

    public func renameDelegationRole(_ name: String, to newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        let nameError = nameChecker()
        return try await delegationWrite(.renameRole(name, to: newName), ifMatch: ifMatch) {
            try $0.renameRole(name, to: newName, nameError: nameError)
        }
    }

    public func deleteDelegationRole(_ name: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.deleteRole(name), ifMatch: ifMatch) { try $0.deleteRole(name) }
    }

    public func addDelegationProfile(name: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        let nameError = nameChecker()
        return try await delegationWrite(.addProfile(name), ifMatch: ifMatch) { try $0.addProfile(name, nameError: nameError) }
    }

    public func renameDelegationProfile(_ name: String, to newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        let nameError = nameChecker()
        return try await delegationWrite(.renameProfile(name, to: newName), ifMatch: ifMatch) {
            try $0.renameProfile(name, to: newName, nameError: nameError)
        }
    }

    public func duplicateDelegationProfile(_ name: String, as newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        let nameError = nameChecker()
        return try await delegationWrite(.duplicateProfile(name, as: newName), ifMatch: ifMatch) {
            try $0.duplicateProfile(name, as: newName, nameError: nameError)
        }
    }

    public func deleteDelegationProfile(_ name: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await delegationWrite(.deleteProfile(name), ifMatch: ifMatch) { try $0.deleteProfile(name) }
    }

    /// An edit made outside the app: a cell changes and the revision moves on.
    public func externalDelegationChange(profile: String, role: String, target: LeoDelegationTarget) {
        delegationState?.profiles[profile]?.cells[role] = target.template.isEmpty ? nil : target
        revisionNumber += 1
    }

    // MARK: internals

    private func requireDelegation() throws -> LeoFakeDelegationState {
        guard let state = delegationState else {
            throw LeoDaemonError.daemon(code: "delegation_not_configured", message: "delegation not configured", matches: [])
        }
        return state
    }

    /// The daemon's name rules, with the names of nothing else taken (each mutator checks its own clashes).
    private func nameChecker() -> @Sendable (String) -> String? {
        let validator = LeoConfigValidator(resource: LeoConfigResource(key: "delegation", kind: .collection, fields: []), namePattern: schemaValue.namePattern)
        return { validator.nameError($0, existing: []) }
    }

    /// One revision-gated write: recorded, held if the test holds writes, gated
    /// on `If-Match`, applied, and answered with the refreshed document. Every
    /// delegation write leaves the daemon and agents needing a restart.
    private func delegationWrite(
        _ write: LeoFakeDelegationWrite, ifMatch: String, _ mutate: (inout LeoFakeDelegationState) throws -> Void
    ) async throws -> LeoDelegationWriteResult {
        calls.append(.delegationWrite(write, ifMatch: ifMatch))
        if isHoldingWrites { await withCheckedContinuation { heldWrites.append($0) } }
        try beforeWrite(ifMatch)
        var state = try requireDelegation()
        try mutate(&state)
        delegationState = state
        revisionNumber += 1
        restartRequired = LeoConfigRestartRequired(service: true, agents: true)
        return LeoDelegationWriteResult(revision: revision, restartRequired: restartRequired, item: state.document(revision: revision))
    }
}
