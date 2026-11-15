import Foundation

extension LeoConfigHTTPClient: LeoDelegationAPI {
    public func delegation() async throws -> LeoDelegationDocument {
        try await read(route())
    }

    public func delegationPreview(profile: String) async throws -> LeoDelegationPreview {
        try await read("\(route("preview"))?profile=\(try Self.segment(profile, what: "Profile name"))")
    }

    public func setDelegationCell(profile: String, role: String, target: LeoDelegationTarget, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange(
            "PUT", route("profiles", try profileName(profile), "roles", try roleName(role)),
            body: ["template": .string(target.template), "model": .string(target.model), "effort": .string(target.effort)], ifMatch: ifMatch
        )
    }

    public func setRoleUseFor(role: String, useFor: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("PUT", route("roles", try roleName(role)), body: ["use_for": .string(useFor)], ifMatch: ifMatch)
    }

    public func setActiveProfile(_ profile: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("PUT", route("active"), body: ["profile": .string(profile)], ifMatch: ifMatch)
    }

    public func setDelegationEnabled(_ enabled: Bool, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("PUT", route("enabled"), body: ["enabled": .bool(enabled)], ifMatch: ifMatch)
    }

    public func setHiddenAgents(_ names: [String], ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("PUT", route("hide-agents"), body: ["names": .list(names.map { .string($0) })], ifMatch: ifMatch)
    }

    public func addDelegationRole(name: String, template: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("POST", route("roles"), body: ["name": .string(name), "template": .string(template)], ifMatch: ifMatch)
    }

    public func renameDelegationRole(_ name: String, to newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("POST", route("roles", try roleName(name), "rename"), body: ["new_name": .string(newName)], ifMatch: ifMatch)
    }

    public func deleteDelegationRole(_ name: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("DELETE", route("roles", try roleName(name)), ifMatch: ifMatch)
    }

    public func addDelegationProfile(name: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("POST", route("profiles"), body: ["name": .string(name)], ifMatch: ifMatch)
    }

    public func renameDelegationProfile(_ name: String, to newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("POST", route("profiles", try profileName(name), "rename"), body: ["new_name": .string(newName)], ifMatch: ifMatch)
    }

    public func duplicateDelegationProfile(_ name: String, as newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("POST", route("profiles", try profileName(name), "duplicate"), body: ["new_name": .string(newName)], ifMatch: ifMatch)
    }

    public func deleteDelegationProfile(_ name: String, ifMatch: String) async throws -> LeoDelegationWriteResult {
        try await exchange("DELETE", route("profiles", try profileName(name)), ifMatch: ifMatch)
    }

    /// `<prefix>/config/delegation[/<part>…]`; names arrive already escaped.
    private func route(_ parts: String...) -> String {
        (["\(prefix)/config/delegation"] + parts).joined(separator: "/")
    }

    private func profileName(_ name: String) throws -> String { try Self.segment(name, what: "Profile name") }
    private func roleName(_ name: String) throws -> String { try Self.segment(name, what: "Role name") }
}
