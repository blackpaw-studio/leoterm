import SwiftUI

/// The standard bottom bar attached under a selectable list: `+` adds (a plain
/// button, or a pull-down of kinds) and `−` removes the selected row. The same
/// control `LeoConfigCollectionView` draws under its list.
struct LeoListBottomBar<Add: View>: View {
    let canRemove: Bool
    let remove: () -> Void
    @ViewBuilder let add: () -> Add

    var body: some View {
        HStack(spacing: 2) {
            add()
            Button(action: remove) { Image(systemName: "minus") }
                .help("Remove").accessibilityLabel("Remove").disabled(!canRemove)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(LeoSettingsMetrics.rowPadding)
    }
}

/// A bar's `+` when there is one kind of thing to add.
struct LeoBarAddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "plus") }.help(label).accessibilityLabel(label)
    }
}

/// A bar's `+` when there are several kinds: a pull-down listing them.
struct LeoBarAddMenu<Kinds: View>: View {
    let label: String
    @ViewBuilder let kinds: () -> Kinds

    var body: some View {
        Menu(content: kinds) { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(label).accessibilityLabel(label)
    }
}

/// A list that sits inside a form row: a bordered frame sized to its rows, which
/// scrolls past `maxRows`, with the bar attached underneath.
struct LeoEmbeddedList<Selection: Hashable, Rows: View, Add: View>: View {
    static var rowHeight: CGFloat { 34 }
    static var maxRows: Int { 6 }
    /// A form row gives its control its ideal width, which a List doesn't have: ask for room for two columns.
    static var minimumWidth: CGFloat { 400 }

    let rowCount: Int
    @Binding var selection: Selection?
    let remove: () -> Void
    let emptyLabel: String
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let add: () -> Add

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) { rows() }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: Self.rowHeight * CGFloat(min(max(rowCount, 1), Self.maxRows)) + 2 * LeoSettingsMetrics.rowPadding)
                .overlay {
                    if rowCount == 0 { Text(emptyLabel).foregroundStyle(.secondary).allowsHitTesting(false) }
                }
            Divider()
            LeoListBottomBar(canRemove: selection != nil, remove: remove, add: add)
        }
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: LeoSettingsMetrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: LeoSettingsMetrics.cornerRadius).stroke(Color(nsColor: .separatorColor)))
    }
}
