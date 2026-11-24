import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A sidebar section being dragged to a new place (B-438). Declared in
    /// Info.plist; only this process can read it.
    static let leoSidebarSection = UTType(exportedAs: "studio.blackpaw.leo.sidebar-section")
}

/// B-438: the section drag this app started, if any. A drag carries a
/// one-off payload rather than the section's key, and a header takes a
/// drop only when the payload is the current drag's, so nothing dropped
/// from outside the app (or a drag that ended elsewhere) moves a section.
/// App-wide, like the order: a header can be dragged to another window's
/// sidebar.
@MainActor final class LeoSidebarSectionDrags {
    private var current: (payload: String, key: String)?

    var isDragging: Bool { current != nil }

    /// The section being dragged, for the drop target's highlight.
    var currentKey: String? { current?.key }

    /// Starts dragging `key`; returns the payload the drag carries.
    func begin(_ key: String) -> String {
        let payload = UUID().uuidString
        current = (payload, key)
        return payload
    }

    /// The dragged section, if `payload` is the current drag's.
    func draggedKey(forPayload payload: String) -> String? {
        current.flatMap { $0.payload == payload ? $0.key : nil }
    }

    func end() { current = nil }
}

/// What a section header's Move Up / Move Down and drag and drop do.
/// `visible` is the shown sections, top to bottom.
struct LeoSidebarSectionMover {
    let key: String
    let visible: [String]
    let drags: LeoSidebarSectionDrags
    let move: (LeoSidebarSectionOrder.Direction) -> Void
    /// Drops the dragged section on this header: it takes this slot.
    let drop: (_ dragged: String) -> Void

    func canMove(_ direction: LeoSidebarSectionOrder.Direction) -> Bool {
        LeoSidebarSectionOrder.canMove(key, direction, visible: visible)
    }

    /// Where a dragged section would land against this header: below it
    /// when it comes from above, else above it. Nil for itself.
    func landingEdge(of dragged: String) -> VerticalEdge? {
        guard dragged != key, let from = visible.firstIndex(of: dragged), let to = visible.firstIndex(of: key) else { return nil }
        return from < to ? .bottom : .top
    }
}

/// Move Up and Move Down, for a section header's context menu.
struct LeoSidebarSectionMoveItems: View {
    let mover: LeoSidebarSectionMover

    var body: some View {
        Button("Move Up") { mover.move(.up) }.disabled(!mover.canMove(.up))
        Button("Move Down") { mover.move(.down) }.disabled(!mover.canMove(.down))
    }
}

/// A section header as a drag source and drop target: dragging it moves
/// the whole section; a line shows where a section dropped on it lands.
/// The list doesn't reorder while a drag hovers, as in Finder's sidebar.
private struct LeoSidebarSectionDragModifier: ViewModifier {
    let mover: LeoSidebarSectionMover
    @State private var landing: VerticalEdge?

    func body(content: Content) -> some View {
        content
            .onDrag { provider() }
            .onDrop(of: [.leoSidebarSection], delegate: LeoSidebarSectionDropDelegate(mover: mover, landing: $landing))
            .overlay(alignment: landing == .bottom ? .bottom : .top) {
                if landing != nil {
                    Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }

    private func provider() -> NSItemProvider {
        let payload = Data(mover.drags.begin(mover.key).utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.leoSidebarSection.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

private struct LeoSidebarSectionDropDelegate: DropDelegate {
    let mover: LeoSidebarSectionMover
    @Binding var landing: VerticalEdge?

    func validateDrop(info: DropInfo) -> Bool {
        mover.drags.isDragging && info.hasItemsConforming(to: [.leoSidebarSection])
    }

    func dropEntered(info: DropInfo) {
        landing = mover.drags.currentKey.flatMap(mover.landingEdge(of:))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: landing == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { landing = nil }

    func performDrop(info: DropInfo) -> Bool {
        let accepts = landing != nil
        landing = nil
        guard accepts, let provider = info.itemProviders(for: [.leoSidebarSection]).first else { return false }
        let drags = mover.drags
        let drop = mover.drop
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.leoSidebarSection.identifier) { data, _ in
            let payload = data.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                guard let payload, let key = drags.draggedKey(forPayload: payload) else { return }
                drags.end()
                drop(key)
            }
        }
        return true
    }
}

extension View {
    /// Makes a section header draggable and a drop target (B-438).
    func leoSidebarSectionDrag(_ mover: LeoSidebarSectionMover) -> some View {
        modifier(LeoSidebarSectionDragModifier(mover: mover))
    }
}
