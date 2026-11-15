import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// SwiftUI closes an alert, running its dismiss setter (which clears the
/// model's confirmation), before the pressed button's action runs. These
/// follow that order.
@MainActor struct LeoConfigCollectionConfirmationTests {
    private static func harness(_ resource: String = "environments", referencedBy template: String? = nil) async throws -> (model: LeoConfigCollectionModel, fake: LeoFakeConfigClient) {
        let fake = try LeoConfigGolden.client(secretEnvironment: true)
        if let template { await fake.externalChange("templates", name: "coder", values: ["environments": .list([.string(template)])]) }
        let model = LeoConfigCollectionModel(resource: resource, client: fake, revisions: LeoConfigRevisionTracker())
        await model.load()
        return (model, fake)
    }

    @Test func deleteGoesThroughWhenTheAlertHasAlreadyDismissedItself() async throws {
        let (model, fake) = try await Self.harness()
        model.select("work")

        model.requestDelete()
        let asked = try #require(model.confirmation)
        model.cancelConfirmation()
        await model.confirm(asked)

        #expect(model.items.map(\.name) == ["base"])
        #expect(await fake.calls.contains { if case .delete(_, "work", _) = $0 { true } else { false } })
    }

    @Test func discardGoesThroughWhenTheAlertHasAlreadyDismissedItself() async throws {
        let (model, _) = try await Self.harness()
        model.select("work")
        model.set("env", model.draft?.value(at: "env").replacingEnvEntries(["A": "1"]) ?? .null)

        model.select("base")
        let asked = try #require(model.confirmation)
        model.cancelConfirmation()
        await model.confirm(asked)

        #expect(model.selection == "base")
        #expect(!model.isDirty)
    }

    @Test func deletingAnEnvironmentAnItemStillUsesShowsTheDaemonsMessageAndKeepsTheItem() async throws {
        let (model, _) = try await Self.harness(referencedBy: "base")
        model.select("base")

        model.requestDelete()
        let asked = try #require(model.confirmation)
        model.cancelConfirmation()
        await model.confirm(asked)

        #expect(model.errorMessage?.contains("unknown environment \"base\"") == true)
        #expect(model.items.map(\.name) == ["base", "work"])
    }
}
