#if DEBUG
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The DEBUG task fixture decodes through the real wire decoder and replays
/// as the same events a daemon would send.
struct LeoProgressFixtureTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file() throws -> LeoProgressFixture.File {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/progress_fixture.json")
        return try LeoProgressFixture.File(json: Data(contentsOf: url))
    }

    @Test func seedDecodesEachWireStateAndResolvesRelativeTimes() throws {
        let seed = LeoProgressFixture.seed(try file(), now: Self.now)
        let alpha = try #require(seed["alpha"])
        #expect(alpha.map(\.id) == ["build", "lint", "deploy"])
        let build = alpha[0]
        #expect(build.percent == 62 && build.mode == .determinate && build.state == .running)
        #expect(build.startedAt == Self.now.addingTimeInterval(-252))
        #expect(build.etaAt == Self.now.addingTimeInterval(180))
        #expect(alpha[1].state == .succeeded && alpha[1].endedAt != nil)
        #expect(alpha[2].mode == .indeterminate)
        #expect(seed["beta"]?.first?.stale == true)
        #expect(seed["gamma"]?.first?.state == .failed)
    }

    @Test func aStepKeepsTheRunIdentityOfTheSeed() throws {
        let file = try file()
        let seeded = try #require(LeoProgressFixture.seed(file, now: Self.now)["alpha"]?.first)
        let step = try #require(file.script.first?.task)
        let later = try #require(LeoProgressFixture.task(step, id: "build", runBase: Self.now, now: Self.now.addingTimeInterval(2)))
        #expect(later.startedAt == seeded.startedAt)
        #expect(later.percent == 70 && later.revision > seeded.revision)
    }

    @Test func scriptEndsWithARemoval() throws {
        let last = try #require(try file().script.last)
        #expect(last.agent == "gamma" && last.task == nil)
    }
}
#endif
