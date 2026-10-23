import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoMachineMigrationTests {
    @Test func aRemoteSelectionBecomesTheLastSpawnMachineAndTheOldKeyIsDeleted() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("mars", forKey: "leo.selectedHost")

        LeoMachineDefaultsMigration(defaults: defaults).run()

        #expect(defaults.string(forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey) == "mars")
        #expect(defaults.object(forKey: "leo.selectedHost") == nil)
    }

    /// `LeoHostID.local.displayName`, the same spelling the spawn sheet writes.
    @Test func aLocalSelectionBecomesTheLastSpawnMachineToo() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("localhost", forKey: "leo.selectedHost")

        LeoMachineDefaultsMigration(defaults: defaults).run()

        #expect(defaults.string(forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey) == "localhost")
        #expect(defaults.object(forKey: "leo.selectedHost") == nil)
    }

    @Test func anAbsentKeyWritesNothing() {
        let defaults = LeoInMemoryDefaults()

        LeoMachineDefaultsMigration(defaults: defaults).run()

        #expect(defaults.object(forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey) == nil)
    }

    @Test func aSecondRunNeverOverwritesALaterSpawnChoice() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("mars", forKey: "leo.selectedHost")
        let migration = LeoMachineDefaultsMigration(defaults: defaults)
        migration.run()
        defaults.set("venus", forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey)

        migration.run()

        #expect(defaults.string(forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey) == "venus")
    }

    @Test func anExistingLastSpawnMachineWinsOverTheOldSelection() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("venus", forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey)
        defaults.set("mars", forKey: "leo.selectedHost")

        LeoMachineDefaultsMigration(defaults: defaults).run()

        #expect(defaults.string(forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey) == "venus")
        #expect(defaults.object(forKey: "leo.selectedHost") == nil)
    }

    /// The runtime migrates at launch, before it builds any machine
    /// connection.
    @MainActor @Test func theRuntimeMigratesTheOldSelectionWhenItInitialises() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("mars", forKey: "leo.selectedHost")
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })

        _ = LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(), activitySource: activitySource, defaults: defaults,
            templateFetchRunner: LeoRecordingTemplateRunner(),
            chatClient: FakeChatClient()
        )

        #expect(defaults.string(forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey) == "mars")
        #expect(defaults.object(forKey: "leo.selectedHost") == nil)
    }
}
