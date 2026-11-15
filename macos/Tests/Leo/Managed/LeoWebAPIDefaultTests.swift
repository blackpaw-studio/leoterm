import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-339: only a `leo.yaml` with no top-level `web` key is ever given the
/// loopback web API; anything ambiguous is left exactly as it is.
struct LeoWebAPIDefaultTests {
    /// Shaped like the config the daemon writes for a managed install.
    static let daemonGenerated = """
    defaults:
      model: sonnet
    templates:
      assistant:
        model: opus
    tasks: []
    """

    @Test(arguments: [
        daemonGenerated,
        daemonGenerated + "\n",
        daemonGenerated.replacingOccurrences(of: "\n", with: "\r\n"),
        "\u{FEFF}" + daemonGenerated,
        "",
        "# only a comment\n",
        "---\n" + daemonGenerated,
        // Nested or commented `web` is not the top-level section.
        "templates:\n  web:\n    enabled: true\ntasks: []\n",
        "# web:\n  enabled: false\ndefaults: {}\n",
        "websites:\n  - a\n",
    ])
    func aConfigWithoutATopLevelWebKeyIsMissingIt(yaml: String) {
        #expect(LeoWebAPIDefault.classify(yaml: yaml, pathKind: .file) == .missing)
    }

    @Test(arguments: [
        "web:\n  enabled: false\n",
        "defaults: {}\nweb: {}\n",
        "\"web\":\n  enabled: true\n",
        "'web':\n  port: 9000\n",
        "web:\n  port: 9000\n",
        "web : {}\n",
        "web:",
        "\u{FEFF}web:\r\n  enabled: false\r\n",
    ])
    func anyTopLevelWebKeyIsPresent(yaml: String) {
        #expect(LeoWebAPIDefault.classify(yaml: yaml, pathKind: .file) == .present)
    }

    @Test(arguments: [
        "{defaults: {}}\n",
        "defaults: {}\n<<: *base\n",
        "defaults: {}\n---\ntasks: []\n",
        "- a\n- b\n",
    ])
    func ambiguousShapesAreSkipped(yaml: String) {
        guard case .skip = LeoWebAPIDefault.classify(yaml: yaml, pathKind: .file) else {
            Issue.record("expected .skip for \(yaml.debugDescription)")
            return
        }
    }

    @Test(arguments: [LeoPathKind.absent, .directory, .symlink(target: "/elsewhere/leo.yaml")])
    func onlyARegularFileIsConsidered(kind: LeoPathKind) {
        guard case .skip = LeoWebAPIDefault.classify(yaml: Self.daemonGenerated, pathKind: kind) else {
            Issue.record("expected .skip for \(kind)")
            return
        }
    }
}
