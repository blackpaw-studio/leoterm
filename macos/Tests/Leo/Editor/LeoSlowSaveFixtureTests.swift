#if DEBUG
import Foundation
import Testing

@testable import Ghostty

/// The DEBUG-only `LEO_SLOW_SAVE_SECONDS` hold on editor saves, used to
/// screenshot a close waiting on a save.
struct LeoSlowSaveFixtureTests {
    @Test func readsAPositiveDelayFromTheEnvironment() {
        #expect(LeoSlowSaveFixture.delay(environment: [LeoSlowSaveFixture.environmentKey: "30"]) == .seconds(30))
        #expect(LeoSlowSaveFixture.delay(environment: [:]) == nil)
        #expect(LeoSlowSaveFixture.delay(environment: [LeoSlowSaveFixture.environmentKey: "0"]) == nil)
        #expect(LeoSlowSaveFixture.delay(environment: [LeoSlowSaveFixture.environmentKey: "soon"]) == nil)
    }

    @Test func holdsSavesThenWritesUnlessClosedMeanwhile() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let access = LeoSlowSaveFixture.wrap(LeoFileAccessor.local(), delay: .milliseconds(1))
            try await access.write(Data("b".utf8), to: path, expecting: nil)
            #expect(try sandbox.contents("a.txt") == "b")

            await access.close()
            await #expect(throws: LeoFileAccessError.self) { try await access.write(Data("c".utf8), to: path, expecting: nil) }
            #expect(try sandbox.contents("a.txt") == "b")
        }
    }

    /// Left anyway during the hold: the save fails at once and never writes.
    @Test(.timeLimit(.minutes(1)))
    func closingDuringTheHoldFailsTheSaveWithoutWriting() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let access = LeoSlowSaveFixture.wrap(LeoFileAccessor.local(), delay: .seconds(3600))
            let save = Task { try await access.write(Data("b".utf8), to: path, expecting: nil) }
            await access.close()

            await #expect(throws: LeoFileAccessError.self) { try await save.value }
            #expect(try sandbox.contents("a.txt") == "a")
        }
    }
}
#endif
