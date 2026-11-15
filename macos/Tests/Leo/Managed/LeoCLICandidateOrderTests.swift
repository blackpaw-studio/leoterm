import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoCLICandidateOrderTests {
    private static let selfPath = "/home/test/.leo/app/bin/leo"
    private static let bundled = "/Applications/Leo.app/Contents/Helpers/leo"

    private static func marker(bundleID: String = "studio.blackpaw.leo.macos") -> LeoManagedMarker {
        LeoManagedMarker(
            bundleID: bundleID, launchdLabel: "studio.blackpaw.leo.daemon", selfPath: selfPath,
            tmuxPath: "/home/test/.leo/app/tmux/3.6a/tmux", env: nil
        )
    }

    private func cli(
        marker: LeoMarkerState,
        override: String? = nil,
        bundled: String? = LeoCLICandidateOrderTests.bundled,
        executable: Set<String> = []
    ) -> LeoCLI {
        LeoCLI(
            executableOverride: override,
            runner: NeverRunner(),
            path: "/opt/homebrew/bin:/usr/bin",
            bundledExecutable: bundled,
            markerState: { marker },
            expandTilde: { $0.replacingOccurrences(of: "~", with: "/home/test") },
            isExecutable: { executable.contains($0) }
        )
    }

    private let afterMarker = ["/home/test/.local/bin/leo", "/opt/homebrew/bin/leo", "/usr/bin/leo", LeoCLICandidateOrderTests.bundled]

    @Test func ourMarkerPutsSelfPathBeforeEverythingButTheOverride() {
        #expect(cli(marker: .ours(Self.marker())).candidateExecutables == [Self.selfPath] + afterMarker)
    }

    @Test func aForeignMarkersSelfPathStillCounts() {
        let foreign = LeoMarkerState.foreign(bundleID: "studio.blackpaw.leo.macos.debug", marker: Self.marker(bundleID: "studio.blackpaw.leo.macos.debug"))
        #expect(cli(marker: foreign).candidateExecutables == [Self.selfPath] + afterMarker)
    }

    @Test(arguments: [LeoMarkerState.absent, .invalid("malformed JSON")])
    func noUsableMarkerStartsAtTheUserInstall(state: LeoMarkerState) {
        #expect(cli(marker: state).candidateExecutables == afterMarker)
    }

    @Test func aMissingBundledHelperIsLeftOut() {
        let list = cli(marker: .absent, bundled: nil).candidateExecutables
        #expect(list == ["/home/test/.local/bin/leo", "/opt/homebrew/bin/leo", "/usr/bin/leo"])
    }

    @Test func duplicatesKeepTheirFirstPosition() {
        let cli = LeoCLI(
            runner: NeverRunner(),
            path: "/home/test/.local/bin:/usr/bin",
            bundledExecutable: "/usr/bin/leo",
            markerState: { .absent },
            expandTilde: { $0.replacingOccurrences(of: "~", with: "/home/test") },
            isExecutable: { _ in false }
        )
        #expect(cli.candidateExecutables == ["/home/test/.local/bin/leo", "/usr/bin/leo"])
    }

    @Test func resolvesTheFirstExecutableCandidateInOrder() throws {
        let all: Set = [Self.selfPath, "/home/test/.local/bin/leo", "/usr/bin/leo", Self.bundled]
        #expect(try cli(marker: .ours(Self.marker()), executable: all).resolveExecutable() == Self.selfPath)
        #expect(try cli(marker: .ours(Self.marker()), executable: all.subtracting([Self.selfPath])).resolveExecutable() == "/home/test/.local/bin/leo")
        #expect(try cli(marker: .ours(Self.marker()), executable: ["/usr/bin/leo", Self.bundled]).resolveExecutable() == "/usr/bin/leo")
        #expect(try cli(marker: .ours(Self.marker()), executable: [Self.bundled]).resolveExecutable() == Self.bundled)
    }

    @Test func theOverrideWinsAndNeverFallsThroughWhenItIsNotExecutable() throws {
        let present = cli(marker: .ours(Self.marker()), override: "/custom/leo", executable: ["/custom/leo", Self.selfPath])
        #expect(try present.resolveExecutable() == "/custom/leo")

        let missing = cli(marker: .ours(Self.marker()), override: "/custom/leo", executable: [Self.selfPath])
        #expect(throws: LeoDaemonError.transport("leo executable is not executable: /custom/leo")) { try missing.resolveExecutable() }
    }

    @Test func theErrorListsEveryCandidateInOrder() {
        let none = cli(marker: .ours(Self.marker()))
        #expect(throws: LeoDaemonError.transport(
            "leo executable not found; tried: \(Self.selfPath), /home/test/.local/bin/leo, /opt/homebrew/bin/leo, /usr/bin/leo, \(Self.bundled)"
        )) { try none.resolveExecutable() }
    }
}

private struct NeverRunner: LeoProcessRunning {
    func run(executable _: String, arguments _: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        Issue.record("runner must not be used")
        return LeoProcessResult(stdout: Data(), stderr: Data(), status: 1)
    }
}
