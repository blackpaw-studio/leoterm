import LeoKit
import SwiftUI

/// The "Tasks" popover under the capsule: every task in primary order, with
/// Dismiss on ended ones. There are no stop buttons: nothing can stop a task.
struct LeoActivityPopover: View {
    static let width: CGFloat = 340
    private static let tileSize: CGFloat = 32

    let presentation: LeoActivityCapsulePresentation.Popover
    let dismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").font(.headline)
                Text(presentation.summary).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            ForEach(presentation.rows) { row in
                rowView(row)
            }
        }
        .padding(14)
        .frame(width: Self.width)
    }

    private func rowView(_ row: LeoActivityCapsulePresentation.Row) -> some View {
        HStack(alignment: .center, spacing: 10) {
            tile(row.tile)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if row.canDismiss {
                        Button("Dismiss") { dismiss(row.id) }.buttonStyle(.link).font(.subheadline)
                    }
                }
                LeoTaskBar(kind: row.bar, height: 4)
                Text(row.statusLine).font(.subheadline).foregroundStyle(row.tile == .failed ? Color.red : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func tile(_ tile: LeoActivityCapsulePresentation.Row.Tile) -> some View {
        let (symbol, tint) = Self.appearance(of: tile)
        return Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.15)))
            .accessibilityHidden(true)
    }

    private static func appearance(of tile: LeoActivityCapsulePresentation.Row.Tile) -> (String, Color) {
        switch tile {
        case .running: ("arrow.triangle.2.circlepath", .accentColor)
        case .succeeded: ("checkmark", .green)
        case .failed: ("exclamationmark.triangle.fill", .red)
        case .cancelled: ("slash.circle", .secondary)
        }
    }
}
