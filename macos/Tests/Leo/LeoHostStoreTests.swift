import Foundation
import Testing

@testable import Ghostty

struct LeoHostStoreTests {
    @Test func savesAndLoadsHostsSortedByName() throws {
        let defaults = testDefaults()
        let store = LeoHostStore(defaults: defaults)
        let zebra = LeoHostConfiguration(name: "Zebra", sshTarget: "zebra")
        let alpha = LeoHostConfiguration(name: "alpha", sshTarget: "alpha")

        try store.save([zebra, alpha])

        #expect(store.load().map(\.name) == ["alpha", "Zebra"])
    }

    @Test func corruptStoredDataLoadsAnEmptyList() {
        let defaults = testDefaults()
        defaults.set(Data("not json".utf8), forKey: LeoHostStore.key)
        #expect(LeoHostStore(defaults: defaults).load().isEmpty)
    }

    @Test func dropsAndReportsInvalidStoredConfigurations() throws {
        let defaults = testDefaults()
        let valid = LeoHostConfiguration(name: "Build", sshTarget: "build")
        let invalid = LeoHostConfiguration(name: "localhost", sshTarget: "host")
        defaults.set(try JSONEncoder().encode([valid, invalid]), forKey: LeoHostStore.key)
        var problems: [LeoHostStoreProblem] = []
        let store = LeoHostStore(defaults: defaults) { problems = $0 }

        #expect(store.load() == [valid])
        #expect(problems == [.init(host: invalid, errors: [.reservedName])])
    }

    @Test func rejectsDuplicateNamesIgnoringCase() {
        let store = LeoHostStore(defaults: testDefaults())
        #expect(throws: LeoHostStoreError.duplicateName("build")) {
            try store.save([
                LeoHostConfiguration(name: "Build", sshTarget: "one"),
                LeoHostConfiguration(name: "build", sshTarget: "two")
            ])
        }
    }

    @Test func rejectsInvalidConfigurations() {
        let store = LeoHostStore(defaults: testDefaults())
        #expect(throws: LeoHostStoreError.invalidConfiguration("localhost", [.reservedName])) {
            try store.save([LeoHostConfiguration(name: "localhost", sshTarget: "host")])
        }
    }

    private func testDefaults() -> UserDefaults {
        LeoInMemoryDefaults()
    }
}
