import Testing

@testable import Ghostty

struct LeoAPIFlavorTests {
    @Test(arguments: [
        ("0.27.0", LeoAPIFlavor.legacy),
        ("0.28.9", .legacy),
        ("0.29.0", .socketEvents),
        ("0.29.1", .socketEvents),
        ("0.30.0", .socketEvents),
        ("1.0.0", .socketEvents),
        ("v0.29.0", .socketEvents),
        ("0.29.0-rc.1", .socketEvents),
        ("0.29.0+build.7", .socketEvents),
        ("garbage", .legacy),
        ("", .legacy)
    ])
    func selectsFlavorBySemver(version: String, expected: LeoAPIFlavor) {
        #expect(LeoAPIFlavor.select(version: version) == expected)
    }
}
