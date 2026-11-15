import Foundation
import LeoKit

/// What a machine section's header says, decided from the machine's
/// connection, advertised features and latest stats sample. Pure: the
/// header view only draws it.
struct LeoMachineHeaderPresentation: Equatable {
    enum Dot: Equatable { case connected, connecting, offline }

    enum Metric: String, CaseIterable, Equatable {
        case cpu, memory, disk

        /// The three-letter label stacked beside a capsule.
        var shortLabel: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "MEM"
            case .disk: "DSK"
            }
        }

        var title: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .disk: "Disk"
            }
        }
    }

    struct Meter: Equatable, Identifiable {
        let metric: Metric
        /// 0...1; nil draws an empty meter (that probe has no value).
        let fraction: Double?
        let level: LeoMeterLevel
        /// "23%", "3.1/16 GB", or "—".
        let valueText: String
        let tooltip: String

        var id: Metric { metric }
    }

    enum Meters: Equatable {
        /// Stats style Off, or a machine with no connection to sample.
        case hidden
        /// Connected, but nothing to show: dimmed empty meters that hold
        /// the column alignment.
        case unavailable(tooltip: String)
        case values([Meter])
    }

    let name: String
    /// Hover text for the name: This Mac's hostname.
    let nameTooltip: String?
    let dot: Dot
    let meters: Meters
    /// Failed or dropped: the header dims and the section folds.
    let isOffline: Bool
    /// Sanitized failure reason for the offline card.
    let reason: String?
    /// A Reconnect already in flight shows no button.
    let isRetrying: Bool
    /// Header chevron and the section's rows: an offline section is
    /// always folded.
    let isCollapsed: Bool
    let agentCount: Int
    let attentionCount: Int

    var isDimmed: Bool { isOffline }
    var canToggleCollapse: Bool { !isOffline }
    var canNewAgentHere: Bool { dot == .connected }
    var canReconnect: Bool { !isRetrying }
    var showsReconnectButton: Bool { isOffline && canReconnect }
    /// A folded machine with agents needing you reads their count in orange
    /// instead of the plain agent count. An offline machine's rows are
    /// stale, so it shows no count.
    var count: Int? {
        guard !isOffline else { return nil }
        return isAlertCount ? attentionCount : agentCount
    }
    var isAlertCount: Bool { !isOffline && isCollapsed && attentionCount > 0 }
    var accessibilityLabel: String {
        isOffline ? name : "\(name), \(LeoAgentCountText.describing(agentCount))"
    }

    static let thisMacName = "This Mac"
    static let noValue = "—"

    init(
        section: LeoMachineSection, style: LeoStatsStyle, hostName: String, now: Date
    ) {
        let host = section.host
        name = host == .local ? Self.thisMacName : host.displayName
        nameTooltip = host == .local ? hostName : nil
        agentCount = section.sections.reduce(0) { $0 + $1.rows.count }
        attentionCount = section.attentionCount
        let offlineReason: String?
        isOffline = section.connectivity.isOffline
        switch section.connectivity {
        case .loading:
            dot = .connecting
            offlineReason = nil
            isRetrying = false
        case .connected:
            dot = .connected
            offlineReason = nil
            isRetrying = false
        case .failed(let message):
            dot = .offline
            offlineReason = message
            isRetrying = false
        case .disconnected(let reason, let retrying):
            dot = retrying ? .connecting : .offline
            offlineReason = reason
            isRetrying = retrying
        }
        reason = offlineReason.map { LeoConnectionFailurePanel(message: $0, hint: nil).message }
        isCollapsed = section.isCollapsed || section.connectivity.isOffline
        meters = Self.meters(
            connected: section.connectivity == .connected, style: style, features: section.features,
            stats: section.stats, now: now
        )
    }

    static func meters(
        connected: Bool, style: LeoStatsStyle, features: LeoDaemonFeatures, stats: LeoMachineStats?, now: Date
    ) -> Meters {
        guard style.showsMeters, connected else { return .hidden }
        guard let stats else {
            return .unavailable(tooltip: features.contains(.machineStats)
                ? "Waiting for the first stats sample"
                : "Stats unavailable: this machine's daemon doesn't report them")
        }
        let sampled = sampledText(stats.sampledAt, now: now)
        return .values([
            cpuMeter(stats.cpu, sampled: sampled),
            memoryMeter(stats.memory, sampled: sampled),
            diskMeter(stats.disk, sampled: sampled),
        ])
    }

    private static func cpuMeter(_ cpu: LeoMachineStats.CPU?, sampled: String) -> Meter {
        guard let percent = cpu?.percent, let fraction = cpu?.fraction, let cpu else {
            let detail = cpu.map { "\($0.cores) cores · measuring" } ?? "unavailable"
            return Meter(metric: .cpu, fraction: nil, level: .normal, valueText: noValue, tooltip: "CPU \(detail)")
        }
        let text = "\(Int(percent.rounded()))%"
        return Meter(
            metric: .cpu, fraction: fraction, level: .level(fraction: fraction), valueText: text,
            tooltip: "CPU \(text) · \(cpu.cores) cores · \(sampled)"
        )
    }

    private static func memoryMeter(_ memory: LeoMachineStats.Memory?, sampled: String) -> Meter {
        guard let memory, let fraction = memory.fraction else {
            return Meter(metric: .memory, fraction: nil, level: .normal, valueText: noValue, tooltip: "Memory unavailable")
        }
        return Meter(
            metric: .memory, fraction: fraction, level: .level(fraction: fraction),
            valueText: usage(used: memory.usedBytes, total: memory.totalBytes),
            tooltip: "\(detail(used: memory.usedBytes, total: memory.totalBytes, fraction: fraction)) · \(sampled)"
        )
    }

    private static func diskMeter(_ disk: LeoMachineStats.Disk?, sampled: String) -> Meter {
        guard let disk, let fraction = disk.fraction else {
            return Meter(metric: .disk, fraction: nil, level: .normal, valueText: noValue, tooltip: "Disk unavailable")
        }
        return Meter(
            metric: .disk, fraction: fraction, level: .level(fraction: fraction),
            valueText: usage(used: disk.usedBytes, total: disk.totalBytes),
            tooltip: "\(detail(used: disk.usedBytes, total: disk.totalBytes, fraction: fraction)) · \(disk.path) · \(sampled)"
        )
    }

    // MARK: - Text

    private static let bytesPerGB = 1_073_741_824.0
    private static let bytesPerTB = bytesPerGB * 1024

    /// "3.1/16 GB": used and total in the total's unit.
    static func usage(used: Int64, total: Int64) -> String {
        let unit = unit(forTotal: total)
        return "\(number(Double(used) / unit.size))/\(number(Double(total) / unit.size)) \(unit.name)"
    }

    /// "27.2 GB of 32 GB used (85%)".
    static func detail(used: Int64, total: Int64, fraction: Double) -> String {
        let unit = unit(forTotal: total)
        let percent = Int((fraction * 100).rounded())
        return "\(number(Double(used) / unit.size)) \(unit.name) of \(number(Double(total) / unit.size)) \(unit.name) used (\(percent)%)"
    }

    private static func unit(forTotal total: Int64) -> (size: Double, name: String) {
        Double(total) >= bytesPerTB ? (bytesPerTB, "TB") : (bytesPerGB, "GB")
    }

    /// Whole from 100 up, else one decimal with a trailing ".0" dropped.
    private static func number(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func sampledText(_ sampledAt: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(sampledAt).rounded())
        switch seconds {
        case ..<1: return "Sampled just now"
        case 1..<60: return "Sampled \(seconds) s ago"
        default: return "Sampled \(seconds / 60) min ago"
        }
    }
}
