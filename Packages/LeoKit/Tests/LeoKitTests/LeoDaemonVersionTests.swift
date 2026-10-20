import Testing

@testable import LeoKit

struct LeoDaemonVersionTests {
    @Test(arguments: [
        ("v0.33.0", "0.33.0"),
        ("0.33.0+abc", "0.33.0"),
        ("v0.33.0+abc.1", "0.33.0+other"),
        ("leo 0.33.0", "0.33.0"),
        ("leo v0.33.0\n", "0.33.0"),
        ("0.33", "0.33.0"),
        ("0.33.0-dev.1", "0.33.0-dev.1+sha")
    ])
    func sameRelease(lhs: String, rhs: String) throws {
        let left = try #require(LeoDaemonVersion(parsing: lhs))
        let right = try #require(LeoDaemonVersion(parsing: rhs))
        #expect(left.isSameRelease(as: right))
        #expect(right.isSameRelease(as: left))
    }

    @Test(arguments: [
        ("0.33.0-dev.1", "0.33.0"),
        ("0.33.0-dev.1", "0.33.0-dev.2"),
        ("0.33.0", "0.33.1"),
        ("0.33.0", "0.34.0"),
        ("1.33.0", "0.33.0")
    ])
    func differentRelease(lhs: String, rhs: String) throws {
        let left = try #require(LeoDaemonVersion(parsing: lhs))
        let right = try #require(LeoDaemonVersion(parsing: rhs))
        #expect(!left.isSameRelease(as: right))
    }

    @Test(arguments: ["garbage", "", "v", "1", "0.x.1", "0..1", "0.33.", "leo", "-1.0.0", "0.33.0-"])
    func rejectsUnparseable(raw: String) {
        #expect(LeoDaemonVersion(parsing: raw) == nil)
    }

    @Test func exposesComponents() throws {
        let version = try #require(LeoDaemonVersion(parsing: "v1.2.3-rc.1+build.7"))
        #expect(version.major == 1)
        #expect(version.minor == 2)
        #expect(version.patch == 3)
        #expect(version.prerelease == "rc.1")
        #expect(version.build == "build.7")
    }
}
