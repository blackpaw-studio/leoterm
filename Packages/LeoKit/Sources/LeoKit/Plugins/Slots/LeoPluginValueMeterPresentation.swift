import Foundation

/// What a renderer needs to draw and voice a value `Meter`, kept pure so the
/// rules are tested without a view: the fill width, the VoiceOver text, and
/// the tone it maps to.
public struct LeoPluginValueMeterPresentation: Equatable, Sendable {
    public let meter: LeoPluginNode.ValueMeter

    public init(_ meter: LeoPluginNode.ValueMeter) { self.meter = meter }

    /// "label, valueText, detail", skipping parts that are missing or empty.
    public var accessibilityLabel: String {
        [meter.label, meter.valueText, meter.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The value as a whole percent, for a level indicator's accessibility value.
    public var accessibilityPercent: Int { Int((meter.value * 100).rounded()) }

    /// The renderer's existing tone for this meter's tint (neutral draws as secondary).
    public var tone: LeoPluginTone {
        switch meter.tone {
        case .neutral: .secondary
        case .success: .success
        case .warning: .warning
        case .failure: .failure
        }
    }

    /// Warning and failure set the value text semibold, so the tone never
    /// depends on colour alone.
    public var emphasizesValueText: Bool { meter.tone == .warning || meter.tone == .failure }

    /// Width of the fill inside a track. Zero draws nothing; any value above
    /// zero is at least as wide as the track is high (a dot), and the fill
    /// never passes the track's end.
    public func fillWidth(trackWidth: Double, trackHeight: Double) -> Double {
        guard trackWidth > 0, meter.value > 0 else { return 0 }
        let share = meter.value * trackWidth
        return Swift.min(Swift.max(share, trackHeight), trackWidth)
    }
}
