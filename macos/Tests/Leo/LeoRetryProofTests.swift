import Foundation
import Testing

// DO NOT MERGE. Temporary CI proof of the unit-test retry (run-unit-tests.sh):
// each test fails the first time it runs on a machine and passes after,
// keyed by a marker file that survives into the retry's new process.
enum LeoRetryProof {
    /// Fails (once) unless this key has already run: the first run leaves the marker and fails.
    static func failOnFirstRun(_ key: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("leo-retry-proof")
        let marker = dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        Issue.record("first attempt of \(key): failing on purpose so the retry has something to prove", sourceLocation: sourceLocation)
    }
}

struct LeoRetryProofPlainTests {
    @Test func failsOnceThenPasses() {
        LeoRetryProof.failOnFirstRun("plain")
    }

    @Test(arguments: ["alpha", "beta"])
    func parameterizedFailsOnceThenPasses(_ name: String) {
        LeoRetryProof.failOnFirstRun("parameterized-\(name)")
    }
}

extension LeoAppEventQueueTests {
    struct LeoRetryProofExtensionTests {
        @Test func failsOnceThenPasses() {
            LeoRetryProof.failOnFirstRun("extension")
        }
    }
}
