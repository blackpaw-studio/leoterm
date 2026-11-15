import Combine
import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginSpawnTemplateModelTests {
    private final class Feed {
        let lists: [String: CurrentValueSubject<LeoTemplateListState, Never>]
        private(set) var reloaded: [String] = []
        init(_ lists: [String: LeoTemplateListState]) { self.lists = lists.mapValues { .init($0) } }
        var asFeed: LeoPluginSpawnTemplateFeed {
            LeoPluginSpawnTemplateFeed(
                list: { [lists] in (lists[$0] ?? .init(.failed("unknown"))).eraseToAnyPublisher() },
                reload: { [self] in reloaded.append($0) })
        }
    }

    private func templates(_ names: String...) -> LeoTemplateListState { .loaded(names.map { LeoTemplate(name: $0) }) }

    @Test func thePluginsTemplateIsPreselectedOnceItsMachineListLoads() {
        let feed = Feed(["a": templates("implementer", "reviewer")])
        let model = LeoPluginSpawnTemplateModel(machine: "a", preselect: "reviewer", feed: feed.asFeed)
        #expect(model.template == "reviewer")
        #expect(model.isReady)
    }

    @Test func noTemplateIsSelectedWhenTheProposedOneIsMissingOrAbsent() {
        let feed = Feed(["a": templates("implementer")])
        #expect(LeoPluginSpawnTemplateModel(machine: "a", preselect: "ghost", feed: feed.asFeed).template == "")
        let none = LeoPluginSpawnTemplateModel(machine: "a", preselect: nil, feed: feed.asFeed)
        #expect(none.template == "")
        #expect(!none.isReady)
    }

    @Test func changingMachineRereadsTemplatesAndDropsASelectionTheNewMachineLacks() {
        let feed = Feed(["a": templates("implementer", "reviewer"), "b": templates("reviewer", "plan")])
        let model = LeoPluginSpawnTemplateModel(machine: "a", preselect: "implementer", feed: feed.asFeed)
        model.template = "implementer"
        model.machine = "b"
        #expect(feed.reloaded == ["b"])
        #expect(model.templateNames == ["reviewer", "plan"])
        #expect(model.template == "")
        model.template = "reviewer"
        model.machine = "a"
        #expect(model.template == "reviewer")   // still offered, stays selected
    }

    @Test func aListThatLoadsLaterPreselectsAndFailuresAreSurfaced() {
        let feed = Feed(["a": .loading])
        let model = LeoPluginSpawnTemplateModel(machine: "a", preselect: "x", feed: feed.asFeed)
        #expect(!model.isReady && model.templateError == nil)
        feed.lists["a"]?.send(templates("x"))
        #expect(model.template == "x" && model.isReady)
        feed.lists["a"]?.send(.failed("offline"))
        #expect(model.templateError?.contains("offline") == true)
        #expect(!model.isReady)
    }
}
