import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-309 / B-310: the Rings stats style drew its 2.5 pt stroke centred on
/// the circle's edge, so each ring spilled 1.25 pt past its 20 pt frame --
/// neighbours nearly touched and a clipping container cut the outer edge.
/// These rasterise the real `LeoMachineMeterCluster` and measure where the
/// ink lands, in points, against the cluster's own layout frame.
@MainActor @Suite(.serialized)
struct LeoRingMeterGeometryTests {
    /// Room around the cluster so ink that escapes its frame is captured, not cut.
    private static let margin: CGFloat = 8

    @Test func ringsStayInsideTheClusterFrameSoNothingClips() throws {
        let ink = try Self.renderedInk()

        #expect(ink.bounds.minX >= ink.frame.minX - 0.5, "ink \(ink.bounds) spills left of the frame \(ink.frame)")
        #expect(ink.bounds.maxX <= ink.frame.maxX + 0.5, "ink \(ink.bounds) spills right of the frame \(ink.frame)")
        #expect(ink.bounds.minY >= ink.frame.minY - 0.5, "ink \(ink.bounds) spills above the frame \(ink.frame)")
        #expect(ink.bounds.maxY <= ink.frame.maxY + 0.5, "ink \(ink.bounds) spills below the frame \(ink.frame)")
    }

    @Test func neighbouringRingsAreSeparatedByAVisibleGap() throws {
        let ink = try Self.renderedInk()

        #expect(ink.columnRuns.count == 3, "expected three separate rings, found runs \(ink.columnRuns)")
        for (left, right) in zip(ink.columnRuns, ink.columnRuns.dropFirst()) {
            #expect(right.lowerBound - left.upperBound >= 4, "rings \(left) and \(right) are too close")
        }
    }

    /// B-330: in the Capsules style the next metric's stacked key sat 3 pt
    /// from the previous capsule, so CPU / MEM / DSK read as one crowded run.
    @Test func capsuleMetersAreSeparatedByAVisibleGapFromTheNextKey() throws {
        let ink = try Self.renderedInk(style: .capsules)

        // Each metric draws a key run then a capsule run: six runs in all.
        #expect(ink.columnRuns.count == 6, "expected three key+capsule pairs, found runs \(ink.columnRuns)")
        for pair in stride(from: 1, to: ink.columnRuns.count - 1, by: 2) {
            let capsule = ink.columnRuns[pair], nextKey = ink.columnRuns[pair + 1]
            #expect(nextKey.lowerBound - capsule.upperBound >= 8, "capsule \(capsule) and next key \(nextKey) are too close")
        }
    }

    // MARK: - Harness

    private struct Ink {
        let frame: CGRect
        let bounds: CGRect
        /// Maximal runs of columns holding any ink, as x ranges in points.
        let columnRuns: [Range<CGFloat>]
    }

    private static func renderedInk(style: LeoStatsStyle = .rings) throws -> Ink {
        let cluster = LeoMachineMeterCluster(meters: Self.meters, style: style)
        let host = NSHostingView(rootView: cluster)
        let size = host.fittingSize
        let canvas = NSHostingView(rootView: cluster.padding(margin))
        canvas.frame = NSRect(origin: .zero, size: CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.close() }
        canvas.layoutSubtreeIfNeeded()

        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / canvas.bounds.width

        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var inkedColumns = Set<Int>()
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                inkedColumns.insert(x)
            }
        }
        try #require(maxX >= 0, "nothing was drawn")

        let sorted = inkedColumns.sorted()
        let runs = sorted.reduce(into: [ClosedRange<Int>]()) { runs, x in
            if let last = runs.last, last.upperBound + 1 == x { runs[runs.count - 1] = last.lowerBound ... x } else { runs.append(x ... x) }
        }
        return Ink(
            frame: CGRect(origin: CGPoint(x: margin, y: margin), size: size),
            bounds: CGRect(
                x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
            ),
            columnRuns: runs.map { (CGFloat($0.lowerBound) / scale) ..< (CGFloat($0.upperBound + 1) / scale) }
        )
    }

    private static let meters: LeoMachineHeaderPresentation.Meters = {
        let gb: Int64 = 1_073_741_824
        let sample = LeoMachineStats(
            sampledAt: Date(), cpu: .init(percent: 63, cores: 8),
            memory: .init(usedBytes: Int64(0.59 * 16 * Double(gb)), totalBytes: 16 * gb),
            disk: .init(path: "/", usedBytes: Int64(0.83 * 512 * Double(gb)), totalBytes: 512 * gb)
        )
        return LeoMachineHeaderPresentation.meters(
            connected: true, style: .rings, features: LeoDaemonFeatures(["machine_stats"]), stats: sample, now: sample.sampledAt
        )
    }()
}
