import Foundation
import Testing

/// Leo.app registers its bundled daemon with `SMAppService.agent(plistName:)`,
/// which needs the LaunchAgent plist inside the bundle at
/// `Contents/Library/LaunchAgents/<LeoDaemonLabel>.plist`. Debug builds use
/// their own label so they can never take over the production daemon's job.
struct LeoBundledLaunchAgentTests {
    #if DEBUG
    private static let expectedLabel = "studio.blackpaw.leo.daemon.debug"
    #else
    private static let expectedLabel = "studio.blackpaw.leo.daemon"
    #endif

    private static func label() throws -> String {
        try #require(Bundle.main.object(forInfoDictionaryKey: "LeoDaemonLabel") as? String)
    }

    private static func agentPlist() throws -> [String: Any] {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent("\(try label()).plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func infoPlistCarriesThisBuildsDaemonLabel() throws {
        #expect(try Self.label() == Self.expectedLabel)
    }

    @Test func launchAgentPlistIsBundledUnderItsLabel() throws {
        let plist = try Self.agentPlist()
        #expect(plist["Label"] as? String == Self.expectedLabel)
    }

    @Test func launchAgentRunsTheBundledLeoSupervised() throws {
        let plist = try Self.agentPlist()
        #expect(plist["BundleProgram"] as? String == "Contents/Helpers/leo")
        #expect(plist["ProgramArguments"] as? [String] == ["leo", "service", "--supervised"])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [Bundle.main.bundleIdentifier ?? ""])
    }
}
