import LeoKit
import SwiftUI

/// Roles down, profiles across: a cell per profile × role that opens its editor.
/// The grid scrolls sideways when the profiles outgrow the window, and the role
/// column stays where it was written, not pinned, so the matrix reads as one table.
struct LeoDelegationMatrixView: View {
    static let roleColumnWidth: CGFloat = 230
    static let profileColumnWidth: CGFloat = 184

    @ObservedObject var model: LeoDelegationSettingsModel
    @Binding var request: LeoDelegationRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Role routing").font(.headline)
                Spacer()
                Button { request = .addRole } label: { Label("Add Role", systemImage: "plus") }
                    .disabled(!model.canRestructure || model.templates.isEmpty)
                    .help(model.templates.isEmpty ? "Add a template first" : "Route a new role to a template in the active profile")
                Button { request = .addProfile } label: { Label("Add Profile", systemImage: "plus") }
                    .disabled(!model.canRestructure)
            }
            if model.matrix.rows.isEmpty {
                Text("No roles yet.").foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        grid.padding(.bottom, 12)
                    }
                    .onAppear { reveal(model.matrix.activeProfile?.name, with: proxy, animated: false) }
                    .onChange(of: model.matrix.activeProfile?.name) { reveal($0, with: proxy, animated: true) }
                }
            }
        }
    }

    /// Brings the active profile's column into a pane that scrolls sideways.
    private func reveal(_ profile: String?, with proxy: ScrollViewProxy, animated: Bool) {
        guard let profile else { return }
        if animated {
            withAnimation { proxy.scrollTo(profile, anchor: .center) }
        } else {
            proxy.scrollTo(profile, anchor: .center)
        }
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: Self.roleColumnWidth, height: 1)
                ForEach(model.matrix.profiles) { profile in
                    LeoDelegationProfileHeader(model: model, profile: profile, request: $request).id(profile.name)
                }
            }
            ForEach(model.matrix.rows) { row in
                GridRow {
                    LeoDelegationRoleHeader(model: model, role: row.role, request: $request)
                    ForEach(row.cells, id: \.profile) { cell in
                        LeoDelegationCellButton(model: model, role: row.role.name, cell: cell)
                    }
                }
            }
        }
    }
}

/// A profile's column header: its name, whether it is active, and its menu.
private struct LeoDelegationProfileHeader: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let profile: LeoDelegationProfile
    @Binding var request: LeoDelegationRequest?

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if profile.active {
                    Text("Active").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                } else {
                    Text("\(profile.roles.count) \(profile.roles.count == 1 ? "role" : "roles")").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if !profile.active { Button("Make Active…") { Task { await model.requestActivate(profile.name) } } }
                Button("Rename…") { request = .renameProfile(profile.name) }
                Button("Duplicate…") { request = .duplicateProfile(profile.name) }
                Divider()
                Button("Delete…", role: .destructive) { model.requestDeleteProfile(profile.name) }
                    .disabled(!model.canDeleteProfile(profile.name))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.isBusy)
            .help(model.hasUnsavedChanges ? "Save or revert your edits first" : "Actions for \(profile.name)")
            .accessibilityLabel("Actions for profile \(profile.name)")
        }
        .padding(8)
        .frame(width: LeoDelegationMatrixView.profileColumnWidth, alignment: .leading)
        .background(profile.active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// A role's row header: its name, an undeclared mark, its description, and its menu.
private struct LeoDelegationRoleHeader: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let role: LeoDelegationRole
    @Binding var request: LeoDelegationRequest?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(role.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !role.declared {
                        Text("undeclared").font(.caption2).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.15), in: Capsule())
                            .help("No entry under delegation.roles; routed by a profile only")
                    }
                }
                if role.declared {
                    Text(role.useFor.isEmpty ? "No description" : role.useFor)
                        .font(.caption).foregroundStyle(role.useFor.isEmpty ? .tertiary : .secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if role.declared { Button("Edit Description…") { model.beginUseForEdit(role: role.name) } }
                Button("Rename…") { request = .renameRole(role.name) }
                Divider()
                Button("Delete…", role: .destructive) { model.requestDeleteRole(role.name) }
                    .disabled(!model.canDeleteRole(role.name))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Actions for \(role.name)")
            .accessibilityLabel("Actions for role \(role.name)")
        }
        .padding(8)
        .frame(width: LeoDelegationMatrixView.roleColumnWidth, alignment: .leading)
        .popover(isPresented: Binding(
            get: { model.useForEditor?.role == role.name }, set: { if !$0 { model.cancelUseForEdit(role: role.name) } }
        ), arrowEdge: .bottom) {
            LeoDelegationUseForPopover(model: model)
        }
        .accessibilityElement(children: .contain)
    }
}

/// One profile × role cell: what it routes to, or a dash where it routes nothing.
private struct LeoDelegationCellButton: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let role: String
    let cell: LeoDelegationMatrix.Cell

    var body: some View {
        Button { model.beginCellEdit(profile: cell.profile, role: role) } label: { label }
            .buttonStyle(.plain)
            .frame(width: LeoDelegationMatrixView.profileColumnWidth, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .disabled(!model.isConfigured)
            .popover(isPresented: Binding(
                get: { model.cellEditor?.profile == cell.profile && model.cellEditor?.role == role },
                set: { if !$0 { model.cancelCellEdit(profile: cell.profile, role: role) } }
            ), arrowEdge: .bottom) {
                LeoDelegationCellPopover(model: model)
            }
            .accessibilityIdentifier("leo.delegation.cell.\(cell.profile).\(role)")
            .accessibilityLabel("\(role) in \(cell.profile)")
            .accessibilityValue(cell.value.map { "\($0.template), \($0.effectiveModel.isEmpty ? "no model" : $0.effectiveModel)" } ?? "not routed")
    }

    private var background: Color {
        cell.isActive ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor)
    }

    @ViewBuilder private var label: some View {
        if let value = cell.value {
            VStack(alignment: .leading, spacing: 3) {
                Text(value.template).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(value.effectiveModel.isEmpty ? "no model" : value.effectiveModel)
                        .font(.caption.monospaced()).foregroundStyle(value.model.isEmpty ? .secondary : .primary).lineLimit(1)
                        .help(value.effectiveModel)
                    if !value.model.isEmpty {
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary).help("Overrides the template’s model").accessibilityHidden(true)
                    }
                }
                if !value.effort.isEmpty {
                    Text(value.effort).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .padding(8).frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        } else {
            Text("Not routed").font(.caption).foregroundStyle(.tertiary)
                .padding(8).frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
        }
    }
}
