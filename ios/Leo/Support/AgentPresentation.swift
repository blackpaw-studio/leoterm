import LeoFeatures
import LeoKit
import UIKit

/// How an agent's state reads in lists and on its screen.
struct AgentBadge: Equatable {
    let symbol: String
    let tint: UIColor
    let label: String

    init(_ priority: AgentPriority) {
        switch priority {
        case .needsInput: (symbol, tint, label) = ("exclamationmark.bubble.fill", .systemOrange, String(localized: "Needs Input"))
        case .errored: (symbol, tint, label) = ("xmark.octagon.fill", .systemRed, String(localized: "Errored"))
        case .finished: (symbol, tint, label) = ("checkmark.circle.fill", .systemGreen, String(localized: "Finished"))
        case .working: (symbol, tint, label) = ("circle.dotted.circle.fill", .systemBlue, String(localized: "Working"))
        case .idle: (symbol, tint, label) = ("moon.zzz.fill", .systemIndigo, String(localized: "Idle"))
        case .stopped: (symbol, tint, label) = ("stop.circle.fill", .systemGray, String(localized: "Stopped"))
        }
    }
}

extension Agent {
    var badge: AgentBadge { AgentBadge(priority) }

    /// Why a needs-input agent is waiting, when the daemon said.
    var attentionDetail: String? {
        guard priority == .needsInput, let reason = attention?.reason else { return nil }
        let kind = switch reason.kind {
        case .permission: String(localized: "Permission")
        case .question: String(localized: "Question")
        case .elicitation: String(localized: "Input requested")
        }
        let detail = [reason.tool, reason.detail].compactMap { $0 }.joined(separator: " — ")
        return detail.isEmpty ? kind : "\(kind): \(detail)"
    }

    var currentActionText: String? {
        guard let action = currentAction, !isStopped else { return nil }
        let detail = action.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty { return detail }
        return action.kind.flatMap { $0.isEmpty ? nil : $0.capitalized }
    }

    /// The line under the name in the Agents list.
    var summary: String {
        if let detail = attentionDetail { return detail }
        if priority == .working, let action = currentActionText { return action }
        return [badge.label, template].compactMap { $0 }.joined(separator: " · ")
    }

    var statusText: String {
        switch status {
        case .starting: String(localized: "Starting")
        case .running: String(localized: "Running")
        case .stopped: String(localized: "Stopped")
        case .unknown(let raw): raw.capitalized
        case nil: String(localized: "Unknown")
        }
    }

    var environmentText: String {
        guard let environments, !environments.names.isEmpty else { return String(localized: "None") }
        let names = environments.names.joined(separator: ", ")
        return environments.isOverride ? names : String(localized: "\(names) (default)")
    }
}

extension ConnectionStatus {
    var label: String {
        switch self {
        case .offline: String(localized: "Offline")
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .reconnecting(let attempt, _): String(localized: "Reconnecting (attempt \(attempt))…")
        case .unauthorized: String(localized: "Pair again")
        }
    }

    var detail: String? {
        switch self {
        case .reconnecting(_, let reason), .unauthorized(let reason): reason
        case .offline, .connecting, .connected: nil
        }
    }

    var tint: UIColor {
        switch self {
        case .connected: .systemGreen
        case .connecting, .reconnecting: .systemOrange
        case .unauthorized: .systemRed
        case .offline: .systemGray
        }
    }
}

extension PairedDaemon {
    /// "leo.example.com" or "10.0.2.10:8370".
    var displayHost: String {
        guard let host = baseURL.host() else { return baseURL.absoluteString }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }
}

/// A tinted capsule label, for attention badges.
final class BadgeView: UIView {
    private let label = UILabel()

    init(text: String, tint: UIColor) {
        super.init(frame: .zero)
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = tint.withAlphaComponent(0.15)
        layer.cornerCurve = .continuous
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
