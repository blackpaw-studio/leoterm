import AppKit
import Combine
import Foundation
import Testing
@testable import Ghostty

/// B-283 fix round 1: Edit Order… attaches to a real terminal window (no
/// content view controller); the spawn sheet's Environments section follows
/// the host's features live and keeps the user's edits across a catalog
/// republish; the template-defaults decoder reads the one key constant.
@MainActor struct LeoEnvironmentFixRoundTests {
    private static let catalog = LeoEnvironmentCatalog(names: ["aws", "prod", "dev"], templateDefaults: ["claude": ["aws", "prod"], "bare": []])

    @Test func sheetHostFindsAWindowWithoutAContentViewController() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView()
        #expect(window.contentViewController == nil)
        let host = try #require(LeoSheetHost.viewController(for: window))
        #expect(host.view.window === window)
        #expect(LeoSheetHost.viewController(for: nil) == nil)
    }

    private struct Harness {
        let features = CurrentValueSubject<Bool, Never>(false)
        let catalog = CurrentValueSubject<LeoEnvironmentCatalogState, Never>(.loaded(LeoEnvironmentFixRoundTests.catalog))
        let model: SpawnAgentModel

        @MainActor init(supported: Bool = false) {
            features.send(supported)
            model = SpawnAgentModel(
                templateList: Just(.loaded([LeoTemplate(name: "claude"), LeoTemplate(name: "bare")])).eraseToAnyPublisher(),
                environmentCatalog: catalog.eraseToAnyPublisher(), environmentsSupported: features.eraseToAnyPublisher()
            )
            model.template = "claude"
        }
    }

    @Test func sectionAppearsOnceTheFeatureIsAdvertised() {
        let harness = Harness(supported: false)
        #expect(!harness.model.showsEnvironments)
        harness.features.send(true)
        #expect(harness.model.showsEnvironments)
        #expect(harness.model.environments.names == ["aws", "prod"])
    }

    @Test func sectionDisappearsAndSendsNothingOnAnOlderDaemon() {
        let harness = Harness(supported: true)
        harness.model.environments = harness.model.environments.adding("dev")
        #expect(harness.model.request().environments == ["aws", "prod", "dev"])
        harness.features.send(false)
        #expect(!harness.model.showsEnvironments)
        #expect(harness.model.request().environments == nil)
    }

    @Test func catalogRepublishKeepsEdits() {
        let harness = Harness(supported: true)
        harness.model.environments = harness.model.environments.removing("aws").adding("dev")
        harness.catalog.send(.loaded(Self.catalog))
        #expect(harness.model.environments.names == ["prod", "dev"])
        #expect(harness.model.request().environments == ["prod", "dev"])
    }

    @Test func templateChangeResetsToItsDefaults() {
        let harness = Harness(supported: true)
        harness.model.environments = harness.model.environments.adding("dev")
        harness.model.template = "bare"
        #expect(harness.model.environments.names.isEmpty)
        harness.model.template = "claude"
        #expect(harness.model.environments.names == ["aws", "prod"])
        #expect(harness.model.request().environments == nil)
    }

    @Test func templateDefaultsDecoderReadsTheKeyConstant() throws {
        let data = Data(#"{"ok":true,"data":[{"name":"claude","envs":["aws"],"environments":["wrong"]}]}"#.utf8)
        #expect(try LeoEnvironmentsWire.templateDefaults(data, namesKey: "envs") == ["claude": ["aws"]])
        #expect(try LeoEnvironmentsWire.templateDefaults(data) == ["claude": ["wrong"]])
    }
}
