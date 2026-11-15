import LeoFeatures
import LeoKit
import UIKit

/// Colours and labels shared by every meter style. Fills are flat solid
/// colours, never gradients.
enum MeterAppearance {
    static let ok = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.184, green: 0.525, blue: 1, alpha: 1) : UIColor(red: 0.102, green: 0.451, blue: 0.941, alpha: 1) }
    static let warning = UIColor.systemOrange
    static let critical = UIColor.systemRed
    static let track = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.1) }
    static let capsuleBorder = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.92, green: 0.92, blue: 0.96, alpha: 0.52) : UIColor(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.5) }
    static let capsuleFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.4) : UIColor(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.08) }
    static let capsuleLabel = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.92, green: 0.92, blue: 0.96, alpha: 0.66) : UIColor(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.72) }

    static func color(_ level: LeoMeterLevel) -> UIColor {
        switch level {
        case .normal: ok
        case .warning: warning
        case .critical: critical
        }
    }

    static func key(_ kind: MachineMeter.Kind) -> String {
        switch kind {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .disk: "DSK"
        }
    }

    static func name(_ kind: MachineMeter.Kind) -> String {
        switch kind {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "Disk")
        }
    }
}

extension LeoStatsStyle {
    var title: String {
        switch self {
        case .capsules: String(localized: "Capsules")
        case .bars: String(localized: "Bars")
        case .rings: String(localized: "Rings")
        case .numbers: String(localized: "Numbers")
        case .off: String(localized: "Off")
        }
    }
}
