import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A borderless header button whose title is both its tooltip and its
/// accessibility label.
struct LeoChatViewerIconButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }
}

/// The open chat file over the whole window: sidebar, terminal and
/// chat. It sits above the sidebar split in the window's top-level
/// stack rather than inside the split, so the split's items, priorities and
/// delegate stay as they are. It ignores the same edges as the split, so it
/// covers exactly the split's rect, below the titlebar in every style.
/// Renders nothing, and takes no clicks, unless a file is full window.
struct LeoChatFullWindowHost: View {
    @ObservedObject var viewer: LeoChatViewerModel
    let session: LeoWindowSession
    let ignoredEdges: Edge.Set

    var body: some View {
        if let document = viewer.fullWindowDocument {
            overlay(for: document)
        }
    }

    /// Arrow keys step only while the message has another image to go to.
    private var stepHandler: ((Int) -> Void)? {
        guard viewer.galleryPosition != nil else { return nil }
        return { session.stepChatGallery($0) }
    }

    private func overlay(for document: LeoChatViewerDocument) -> some View {
        VStack(spacing: 0) {
            header(for: document)
            Divider()
            LeoChatFileViewerRepresentable(
                document: document,
                coversWindow: true,
                onStep: stepHandler,
                onBack: session.exitChatFullWindow,
                openExternally: { NSWorkspace.shared.open($0) }
            )
            .id(document.attachmentID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        // Swallow drops, so a file dragged over the overlay can't reach the
        // chat or terminal underneath.
        .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
        .ignoresSafeArea(.container, edges: ignoredEdges)
        .modifier(ModalTrait())
    }

    private func header(for document: LeoChatViewerDocument) -> some View {
        HStack(spacing: 8) {
            LeoChatViewerIconButton(
                systemImage: "arrow.down.right.and.arrow.up.left", title: "Exit Full Window", action: session.exitChatFullWindow
            )
            Text(document.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let position = viewer.galleryPosition { galleryControls(position) }
            LeoChatViewerIconButton(
                systemImage: "arrow.up.forward.app", title: "Open in Default App", action: { NSWorkspace.shared.open(document.url) }
            )
            LeoChatViewerIconButton(systemImage: "xmark", title: "Close", action: session.closeChatViewer)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

    /// Previous / next image of the message, with where this one sits.
    private func galleryControls(_ position: LeoChatViewerModel.GalleryPosition) -> some View {
        HStack(spacing: 6) {
            LeoChatViewerIconButton(systemImage: "chevron.left", title: "Previous Image", action: { session.stepChatGallery(-1) })
                .disabled(position.index == 0)
            Text("\(position.index + 1) of \(position.count)")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("Image \(position.index + 1) of \(position.count)")
            LeoChatViewerIconButton(systemImage: "chevron.right", title: "Next Image", action: { session.stepChatGallery(1) })
                .disabled(position.index == position.count - 1)
        }
    }

    /// Hides what the overlay covers from VoiceOver where the system can.
    private struct ModalTrait: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 14, *) {
                content.accessibilityAddTraits(.isModal)
            } else {
                content
            }
        }
    }
}
