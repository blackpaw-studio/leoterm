import Foundation
import Testing

@testable import Ghostty

/// Deterministic port prober: `busy` ports are taken, `pickFreePort` hands
/// out `picks` in order. Nothing binds a real port.
final class FakePortProber: LeoPortProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var busy: Set<Int>
    private var picks: [Int]
    private var listening: Set<Int>

    init(busy: Set<Int> = [], picks: [Int] = [49_200, 49_201, 49_202], listening: Set<Int> = []) {
        self.busy = busy
        self.picks = picks
        self.listening = listening
    }

    func isFree(_ port: Int) -> Bool { lock.withLock { !busy.contains(port) } }
    func isListening(_ port: Int) -> Bool { lock.withLock { listening.contains(port) } }
    func pickFreePort() throws -> Int {
        try lock.withLock {
            guard !picks.isEmpty else { throw LeoPortForwardError.noFreePort }
            return picks.removeFirst()
        }
    }
    func markBusy(_ port: Int) { lock.withLock { _ = busy.insert(port) } }
}

struct LeoPortForwardPlannerTests {
    private func planner(remote: Bool = true, busy: Set<Int> = [], picks: [Int] = [49_200, 49_201]) -> LeoPortForwardPlanner {
        LeoPortForwardPlanner(isRemote: remote, prober: FakePortProber(busy: busy, picks: picks))
    }

    @Test(arguments: [
        ("http://localhost:5173/app", 5173),
        ("http://127.0.0.1:3000", 3000),
        ("http://[::1]:8080/x?y=1#z", 8080),
        ("http://localhost/", 80),
        ("https://localhost/", 443)
    ])
    func remoteMachineForwardsLoopbackHosts(_ urlString: String, _ port: Int) throws {
        #expect(planner().remotePort(for: try #require(URL(string: urlString))) == port)
    }

    @Test(arguments: [
        "http://example.com:5173/", "http://192.168.1.5:3000/", "http://localhost.evil.com:3000/",
        "file:///tmp/a.html", "about:blank", "data:text/html,hi"
    ])
    func nonLoopbackOrNonWebURLsAreNotForwarded(_ urlString: String) throws {
        #expect(planner().remotePort(for: try #require(URL(string: urlString))) == nil)
    }

    @Test func theLocalMachineNeverForwards() throws {
        let url = try #require(URL(string: "http://localhost:5173/"))
        #expect(planner(remote: false).remotePort(for: url) == nil)
        #expect(planner(remote: false).toLocal(url, using: [5173: 49_200]) == url)
    }

    @Test func theSamePortIsUsedWhenFree() throws {
        #expect(try planner().localPort(forRemote: 5173, avoiding: []) == 5173)
    }

    @Test func aBusyPortFallsBackToTheProbersPick() throws {
        #expect(try planner(busy: [5173]).localPort(forRemote: 5173, avoiding: []) == 49_200)
    }

    @Test func aPortAlreadyForwardedForAnotherRemotePortIsAvoided() throws {
        #expect(try planner().localPort(forRemote: 5173, avoiding: [5173]) == 49_200)
    }

    @Test func aPickInTheAvoidSetIsSkipped() throws {
        #expect(try planner(busy: [5173]).localPort(forRemote: 5173, avoiding: [5173, 49_200]) == 49_201)
    }

    @Test func toLocalRewritesThePortKeepingPathQueryAndFragment() throws {
        let url = try #require(URL(string: "http://localhost:5173/app/page?a=1&b=2#frag"))
        #expect(planner().toLocal(url, using: [5173: 49_200]).absoluteString == "http://localhost:49200/app/page?a=1&b=2#frag")
    }

    @Test func toRemoteRewritesTheLocalPortBack() throws {
        let url = try #require(URL(string: "http://localhost:49200/app/page?a=1&b=2#frag"))
        #expect(planner().toRemote(url, using: [49_200: 5173]).absoluteString == "http://localhost:5173/app/page?a=1&b=2#frag")
    }

    @Test func aSamePortMappingLeavesTheURLUntouched() throws {
        let url = try #require(URL(string: "http://localhost:5173/a"))
        #expect(planner().toLocal(url, using: [5173: 5173]) == url)
        #expect(planner().toRemote(url, using: [5173: 5173]) == url)
    }

    @Test func nonLoopbackURLsAreUntouchedEvenWhenThePortIsMapped() throws {
        let url = try #require(URL(string: "http://example.com:5173/a"))
        #expect(planner().toLocal(url, using: [5173: 49_200]) == url)
        #expect(planner().toRemote(url, using: [5173: 49_200]) == url)
    }

    @Test func unmappedPortsAreUntouched() throws {
        let url = try #require(URL(string: "http://localhost:9999/a"))
        #expect(planner().toLocal(url, using: [5173: 49_200]) == url)
    }

    @Test func anIPv6LoopbackURLIsReachableThroughTheIPv4OnlyForward() throws {
        let url = try #require(URL(string: "http://[::1]:5173/a"))
        #expect(planner().toLocal(url, using: [5173: 5173]).absoluteString == "http://127.0.0.1:5173/a")
    }
}
