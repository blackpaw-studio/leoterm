import Foundation

@testable import LeoKit

/// A `LeoFakeConfigClient` seeded with the daemon's golden bodies, for the
/// pane-state tests: the same shapes the Mac pane models are tested against.
enum LeoConfigPaneFixtures {
    static func schema() throws -> LeoConfigSchema {
        try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
    }

    static func client(tasks: LeoFakeTaskData = LeoFakeTaskData()) throws -> LeoFakeConfigClient {
        func items(_ name: String) throws -> [LeoConfigItem] {
            try LeoConfigFixtures.decode(LeoConfigCollection.self, name).items
        }
        func singleton(_ name: String) throws -> LeoConfigItem {
            try LeoConfigFixtures.decode(LeoConfigDocument.self, name).item
        }
        return LeoFakeConfigClient(
            schema: try schema(),
            singletons: ["defaults": try singleton("defaults"), "web": try singleton("web"), "client": try singleton("client")],
            collections: [
                "templates": try items("templates"), "tasks": try items("tasks"),
                "environments": try items("environments"), "hosts": try items("hosts"),
            ],
            tasks: tasks
        )
    }

    /// A state that has finished loading `resource` from `client`.
    static func loadedState(
        resource: String = "templates", client: any LeoConfigClient, autoSelectsFirst: Bool = true
    ) async throws -> LeoConfigCollectionState {
        var state = LeoConfigCollectionState(resource: resource, autoSelectsFirst: autoSelectsFirst)
        state.beginLoading()
        state.loaded(await LeoConfigCollectionOps.load(resource: resource, client: client, references: [:]))
        return state
    }
}
