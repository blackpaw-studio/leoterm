import Foundation
import Testing

@testable import Ghostty

struct LeoInMemoryDefaultsTests {
    @Test func storesAndRemovesValues() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("mars", forKey: "leo.selectedHost")
        defaults.set(Data([1, 2]), forKey: "leo.hosts")
        #expect(defaults.string(forKey: "leo.selectedHost") == "mars")
        #expect(defaults.data(forKey: "leo.hosts") == Data([1, 2]))

        defaults.removeObject(forKey: "leo.selectedHost")
        defaults.set(nil, forKey: "leo.hosts")
        #expect(defaults.object(forKey: "leo.selectedHost") == nil)
        #expect(defaults.data(forKey: "leo.hosts") == nil)
    }

    @Test func typedGettersMatchUserDefaultsConversions() {
        let defaults = LeoInMemoryDefaults()
        defaults.set(true, forKey: "flag")
        defaults.set(312.5, forKey: "width")
        defaults.set(7, forKey: "count")
        defaults.set("YES", forKey: "stringFlag")
        #expect(defaults.bool(forKey: "flag"))
        #expect(defaults.object(forKey: "flag") as? Bool == true)
        #expect(defaults.double(forKey: "width") == 312.5)
        #expect((defaults.object(forKey: "width") as? NSNumber)?.doubleValue == 312.5)
        #expect(defaults.integer(forKey: "count") == 7)
        #expect(defaults.string(forKey: "count") == "7")
        #expect(defaults.bool(forKey: "stringFlag"))
        #expect(!defaults.bool(forKey: "missing"))
        #expect(defaults.integer(forKey: "missing") == 0)
    }

    @Test func registeredDefaultsAnswerUntilAValueIsSet() {
        let defaults = LeoInMemoryDefaults()
        defaults.register(defaults: ["leo.sidebarVisible": true])
        #expect(defaults.bool(forKey: "leo.sidebarVisible"))
        defaults.set(false, forKey: "leo.sidebarVisible")
        #expect(!defaults.bool(forKey: "leo.sidebarVisible"))
    }

    /// It never falls through to the host's standard or global domains.
    @Test func startsEmptyAndSeparateFromOtherInstances() {
        let first = LeoInMemoryDefaults()
        let second = LeoInMemoryDefaults()
        first.set("a", forKey: "key")
        #expect(second.object(forKey: "key") == nil)
        #expect(second.object(forKey: "AppleLanguages") == nil)
        #expect(second.dictionaryRepresentation().isEmpty)
    }
}
