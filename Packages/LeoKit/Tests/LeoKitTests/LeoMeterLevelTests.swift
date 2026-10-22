import Testing

@testable import LeoKit

struct LeoMeterLevelTests {
    @Test(arguments: [
        (0.0, LeoMeterLevel.normal),
        (0.799, .normal),
        (0.8, .warning),
        (0.899, .warning),
        (0.9, .critical),
        (1.0, .critical),
    ])
    func mapsFractionToLevel(fraction: Double, expected: LeoMeterLevel) {
        #expect(LeoMeterLevel.level(fraction: fraction) == expected)
    }

    @Test func unknownFractionIsNormal() {
        #expect(LeoMeterLevel.level(fraction: nil) == .normal)
    }

    @Test func zeroTotalMeterIsNormal() {
        let fraction = LeoMachineStats.Disk(path: "/", usedBytes: 99, totalBytes: 0).fraction
        #expect(LeoMeterLevel.level(fraction: fraction) == .normal)
    }
}
