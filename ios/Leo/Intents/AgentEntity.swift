import AppIntents
import LeoFeatures
import LeoKit

/// An agent on a paired machine, as Siri, Shortcuts and the Control's
/// picker see it. Shared by the app and the Controls extension.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentEntityQuery()

    private static let separator: Character = "\u{1F}"

    let target: LeoAgentTarget
    /// The agent's name, or `name · machine` when two machines share it.
    let name: String

    var id: String { "\(target.machineID)\(Self.separator)\(target.agent)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(target.machineName)")
    }

    /// Entities for `targets`, each named against the whole list so duplicates show their machine.
    static func entities(for targets: [LeoAgentTarget]) -> [AgentEntity] {
        targets.map { AgentEntity(target: $0, name: $0.displayName(among: targets)) }
    }

    /// The machine and agent an entity id names; nil for an id that isn't one.
    static func target(forID id: String, in targets: [LeoAgentTarget]) -> LeoAgentTarget? {
        let parts = id.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return targets.first { $0.machineID == parts[0] && $0.agent == parts[1] }
    }
}

/// Reads the snapshot the app keeps in the app group, so it works in the
/// Controls extension (no Keychain there) as well as in the app.
struct AgentEntityQuery: EntityQuery {
    private func snapshot() -> [LeoAgentTarget] {
        LeoAgentDirectorySnapshotStore.appGroup(identifier: AgentDirectoryClient.appGroupIdentifier)?.read() ?? []
    }

    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        let targets = snapshot()
        let all = AgentEntity.entities(for: targets)
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        AgentEntity.entities(for: snapshot())
    }
}
