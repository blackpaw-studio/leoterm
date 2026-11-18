import Foundation
import Testing

@testable import LeoKit

struct LeoDaemonPaneTests {
    @Test func serviceSectionFirst() {
        #expect(LeoDaemonPane.Section.allCases == [.service, .web, .client, .hosts])
        #expect(LeoDaemonPane.Section.allCases.first == .service)
    }

    @Test func clientDefaultHostPicksFromHosts() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let hosts = try await fake.collection(LeoDaemonPane.hostsKey)

        let load = await LeoConfigSingletonOps.load(
            resource: "client", client: fake, references: LeoDaemonPane.hostReferences(hosts.items), transform: LeoDaemonPane.clientResource
        )
        var state = LeoConfigSingletonState(resource: "client")
        state.loaded(load)

        let control = state.sections.flatMap(\.rows).first { $0.path == LeoDaemonPane.defaultHostKey }?.control
        #expect(control == .referencePicker(collection: "hosts", names: ["remote"], emptyLabel: "None"))
    }

    @Test func deleteNoteNamesDefaultHost() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let client = LeoConfigDraft(document: try await fake.document("client"))

        #expect(LeoDaemonPane.deleteNote(forHost: "remote", client: client)?.contains("default host") == true)
        #expect(LeoDaemonPane.deleteNote(forHost: "staging", client: client) == nil)
        #expect(LeoDaemonPane.deleteNote(forHost: "remote", client: nil) == nil)
    }
}
