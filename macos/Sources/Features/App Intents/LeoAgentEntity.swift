import AppIntents
import LeoKit

/// An agent on a paired machine, as Shortcuts and Siri name it. The id
/// encodes machine plus agent, so the same name on two machines stays two
/// entities.
@available(macOS 15.0, *)
struct LeoAgentEntity: AppEntity {
    private static let separator: Character = "\u{1F}"

    let id: String
    let label: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Agent" }
    static var defaultQuery: LeoAgentQuery { LeoAgentQuery() }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }

    init(target: LeoAgentTarget, among targets: [LeoAgentTarget]) {
        id = "\(target.machineID)\(Self.separator)\(target.agent)"
        label = target.displayName(among: targets)
    }

    /// The machine and agent the id names. The machine's display name is
    /// not part of the id; callers get it from the current directory.
    var parts: (machineID: String, agent: String)? {
        guard let split = id.firstIndex(of: Self.separator) else { return nil }
        return (String(id[..<split]), String(id[id.index(after: split)...]))
    }

    /// The directory entry this entity names, if the machine still reports it.
    func target(in directory: LeoAgentDirectory) -> LeoAgentTarget? {
        guard let parts else { return nil }
        return directory.targets.first { $0.machineID == parts.machineID && $0.agent == parts.agent }
    }

    static func entities(in directory: LeoAgentDirectory) -> [LeoAgentEntity] {
        directory.targets.map { LeoAgentEntity(target: $0, among: directory.targets) }
    }
}

@available(macOS 15.0, *)
struct LeoAgentQuery: EntityQuery {
    @Dependency var sender: LeoAgentMessageSender

    func entities(for identifiers: [LeoAgentEntity.ID]) async throws -> [LeoAgentEntity] {
        let wanted = Set(identifiers)
        return LeoAgentEntity.entities(in: await sender.agents()).filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [LeoAgentEntity] {
        LeoAgentEntity.entities(in: await sender.agents())
    }
}
