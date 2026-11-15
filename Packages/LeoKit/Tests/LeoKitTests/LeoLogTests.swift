import Foundation
import Testing

@testable import LeoKit

@Suite(.serialized)
struct LeoLogTests {
    @Test func defaultsToTheMacSubsystem() {
        #expect(LeoLog.defaultSubsystem == "studio.blackpaw.leo.macos")
    }

    @Test func subsystemCanBeReplacedByTheHostApp() {
        let original = LeoLog.subsystem
        defer { LeoLog.subsystem = original }
        LeoLog.subsystem = "studio.blackpaw.leo.ios"
        #expect(LeoLog.subsystem == "studio.blackpaw.leo.ios")
    }
}
