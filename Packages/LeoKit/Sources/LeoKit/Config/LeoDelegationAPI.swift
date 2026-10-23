import Foundation

/// The delegation routes of the config API: a profile × role grid rather than a
/// schema resource, so it has its own reads and thirteen typed writes. Every
/// write names the revision it was based on and answers with the refreshed
/// document. Without a `delegation:` block a read says `configured: false` and
/// every write is a 404 `delegation_not_configured`; there is no route to create one.
public protocol LeoDelegationAPI: Sendable {
    /// `GET /config/delegation`.
    func delegation() async throws -> LeoDelegationDocument
    /// `GET /config/delegation/preview?profile=`: what activating it would change.
    func delegationPreview(profile: String) async throws -> LeoDelegationPreview
    /// `PUT …/profiles/{p}/roles/{r}`: the whole cell. An empty template deletes it.
    func setDelegationCell(profile: String, role: String, target: LeoDelegationTarget, ifMatch: String) async throws -> LeoDelegationWriteResult
    /// `PUT …/roles/{r}`: a declared role's description.
    func setRoleUseFor(role: String, useFor: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    func setActiveProfile(_ profile: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    func setDelegationEnabled(_ enabled: Bool, ifMatch: String) async throws -> LeoDelegationWriteResult
    /// `PUT …/hide-agents`: the whole list; an empty one hides none.
    func setHiddenAgents(_ names: [String], ifMatch: String) async throws -> LeoDelegationWriteResult
    /// `POST …/roles`: the new role is routed to `template` in the active profile.
    func addDelegationRole(name: String, template: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    func renameDelegationRole(_ name: String, to newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    /// Removes the role from every profile.
    func deleteDelegationRole(_ name: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    func addDelegationProfile(name: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    func renameDelegationProfile(_ name: String, to newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    func duplicateDelegationProfile(_ name: String, as newName: String, ifMatch: String) async throws -> LeoDelegationWriteResult
    /// The active profile can't be deleted.
    func deleteDelegationProfile(_ name: String, ifMatch: String) async throws -> LeoDelegationWriteResult
}
