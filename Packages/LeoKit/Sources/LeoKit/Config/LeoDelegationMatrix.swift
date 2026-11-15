import Foundation

/// The delegation grid: roles down, profiles across, a cell where a profile
/// routes a role. Pure, built from one document; every question the view and
/// the delete confirmations ask lives here.
public struct LeoDelegationMatrix: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public let profile: String
        public let isActive: Bool
        /// Nil when this profile doesn't route the role.
        public let value: LeoDelegationCell?
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let role: LeoDelegationRole
        /// One per profile, in `profiles` order.
        public let cells: [Cell]

        public var id: String { role.name }
    }

    public let profiles: [LeoDelegationProfile]
    public let rows: [Row]

    public init(_ document: LeoDelegationDocument) {
        profiles = document.profiles
        let declared = Dictionary(document.roles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // A role only a profile mentions is undeclared even when the daemon didn't list it.
        let mentioned = Set(document.profiles.flatMap { $0.roles.keys }).subtracting(declared.keys).sorted()
        let roles = document.roles + mentioned.map { LeoDelegationRole(name: $0, declared: false) }
        rows = roles.map { role in
            Row(role: role, cells: document.profiles.map { Cell(profile: $0.name, isActive: $0.active, value: $0.roles[role.name]) })
        }
    }

    public var activeProfile: LeoDelegationProfile? { profiles.first { $0.active } }

    public var undeclaredRoles: [String] { rows.filter { !$0.role.declared }.map(\.role.name) }

    public func cell(profile: String, role: String) -> LeoDelegationCell? {
        profiles.first { $0.name == profile }?.roles[role]
    }

    /// The profiles that have a cell for `role`: what deleting it takes it out of.
    public func profilesRouting(role: String) -> [String] {
        profiles.filter { $0.roles[role] != nil }.map(\.name)
    }

    /// The declared roles `profile` has no cell for.
    public func unmappedRoles(in profile: String) -> [String] {
        guard let profile = profiles.first(where: { $0.name == profile }) else { return [] }
        return rows.filter { $0.role.declared && profile.roles[$0.role.name] == nil }.map(\.role.name)
    }

    public func routedRoleCount(in profile: String) -> Int {
        profiles.first { $0.name == profile }?.roles.count ?? 0
    }
}
