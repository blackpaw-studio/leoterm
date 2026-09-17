import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoRequestConfigStoreTests {
    @Test func consumeReturnsAndRemovesTheStoredConfig() {
        let store = LeoRequestConfigStore()
        let requestID = UUID()
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = "/tmp/example"
        store.set(config, for: requestID)

        #expect(store.consume(for: requestID)?.workingDirectory == "/tmp/example")
        // One-shot: a second consume finds nothing.
        #expect(store.consume(for: requestID) == nil)
    }

    @Test func consumeForUnknownRequestReturnsNil() {
        let store = LeoRequestConfigStore()
        #expect(store.consume(for: UUID()) == nil)
    }

    @Test func settingNilIsANoOp() {
        let store = LeoRequestConfigStore()
        let requestID = UUID()
        store.set(nil, for: requestID)
        #expect(store.consume(for: requestID) == nil)
    }

    @Test func dropRemovesWithoutReturning() {
        let store = LeoRequestConfigStore()
        let requestID = UUID()
        store.set(Ghostty.SurfaceConfiguration(), for: requestID)

        store.drop(for: requestID)

        #expect(store.consume(for: requestID) == nil)
    }
}
