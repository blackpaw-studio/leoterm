#if DEBUG
import Foundation
import Testing

@testable import Ghostty

/// `LEO_SURFACE_FIXTURE` (DEBUG): event objects from a file, handed over
/// once, after the first successful list.
@MainActor
struct LeoSurfaceFixtureTests {
    @Test func loadsEventObjectsSkippingBadOnes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("surface-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"""
        [{"type":"file_surfaced","agent":"alpha","started_at":"s1","id":"u-1","path":"a.swift","abs_path":"/w/a.swift","line":3,"reason":"look"},
         {"type":"file_surfaced","agent":"alpha"}]
        """#.utf8).write(to: url)
        let files = try #require(LeoSurfaceFixture.load(environment: [LeoSurfaceFixture.environmentKey: url.path]))
        #expect(files.map(\.id) == ["u-1"])
        #expect(LeoSurfaceFixture.load(environment: [:]) == nil)
        #expect(LeoSurfaceFixture.load(environment: [LeoSurfaceFixture.environmentKey: "/nonexistent/fixture.json"]) == nil)
    }

    @Test func injectsOnceAfterTheFirstSuccessfulList() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let injector = LeoSurfaceFixtureInjector(files: [file])
        var injected: [[LeoSurfacedFile]] = []
        injector.snapshotLanded(LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 1)) { injected.append($0) }
        #expect(injected.isEmpty)
        let listed = LeoSidebarSnapshot(rows: [], connectivity: .connected, generation: 2, listRefreshSucceeded: true)
        injector.snapshotLanded(listed) { injected.append($0) }
        injector.snapshotLanded(listed) { injected.append($0) }
        #expect(injected == [[file]])
    }
}
#endif
