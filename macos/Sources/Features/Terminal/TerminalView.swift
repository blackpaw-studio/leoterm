import SwiftUI
import Combine
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    // MARK: Leo
    let leoSession: LeoWindowSession?

    /// The window edges the sidebar split extends into, past the safe area
    /// (B-074). See `LeoTitlebarInsets`.
    let leoSplitIgnoredEdges: Edge.Set

    /// Mirrors `leoSession.placeholderSurfaceIDs`. `leoSession` is a plain
    /// `let` (an optional cannot be `@ObservedObject`), so this view is not
    /// subscribed to it: rebirthing a placeholder changed the session without
    /// invalidating `body`, and the overlay only appeared once something else
    /// -- a window resize -- forced a re-evaluation. Mirroring the published
    /// set into view state gives SwiftUI the dependency it needs.
    @State private var leoPlaceholderSurfaceIDs: Set<UUID> = []

    /// Publisher for the above; `Empty` keeps the `onReceive` well-typed when
    /// there is no Leo session (a non-Leo window).
    private var leoPlaceholderSurfaceIDsPublisher: AnyPublisher<Set<UUID>, Never> {
        leoSession?.$placeholderSurfaceIDs.eraseToAnyPublisher()
            ?? Empty(completeImmediately: false).eraseToAnyPublisher()
    }

    init(
        ghostty: Ghostty.App,
        viewModel: ViewModel,
        delegate: (any TerminalViewDelegate)?,
        leoSession: LeoWindowSession? = nil,
        leoSplitIgnoredEdges: Edge.Set = []
    ) {
        self.ghostty = ghostty
        self.viewModel = viewModel
        self.delegate = delegate
        self.leoSession = leoSession
        self.leoSplitIgnoredEdges = leoSplitIgnoredEdges
    }

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                // MARK: Leo
                // The placeholder is nested inside the sidebar split's terminal
                // column rather than layered over the whole window: as a ZStack
                // sibling it spanned the full width and its blurred background
                // covered the sidebar, so toggling the sidebar on the start
                // screen slid it out behind the placeholder.
                if let leoSession, let runtime = (NSApp.delegate as? AppDelegate)?.leoRuntime {
                    LeoSidebarSplit(
                        session: leoSession, model: runtime.model, actions: runtime.actions,
                        titlebarIgnoredEdges: leoSplitIgnoredEdges,
                        // B-065: the sidebar footer's buttons are the menu
                        // items' own actions, the same ones the start
                        // screen's buttons send.
                        shortcutHints: runtime.shortcutHints,
                        buttonActions: leoButtonActions,
                        terminal: {
                            ZStack {
                                terminalContent

                                if viewModel.surfaceTree.isEmpty {
                                    leoPlaceholder(session: leoSession, runtime: runtime)
                                }
                            }
                        }
                    )
                } else {
                    terminalContent
                }

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
            .onReceive(leoPlaceholderSurfaceIDsPublisher) { leoPlaceholderSurfaceIDs = $0 }
        }
    }

    /// This window's New Terminal and Quick Terminal buttons (B-065,
    /// B-113), for the sidebar footer and the start screen alike. Built
    /// from the delegate alone, held weakly, never `self`: the sidebar keeps
    /// these closures for the window's life, and a copy of this view holds
    /// the focused surface (`@FocusedValue`), which would keep a displaced
    /// surface and its pty alive.
    private var leoButtonActions: LeoSidebarButtonActions {
        .forWindow(delegate)
    }

    /// The Leo start screen, shown in place of an empty terminal column.
    private func leoPlaceholder(session: LeoWindowSession, runtime: LeoRuntime) -> some View {
        LeoPlaceholderView(
            model: runtime.model,
            hostSelection: runtime.hostSelection,
            shortcutHints: runtime.shortcutHints,
            openPicker: { session.openPicker(surfaceID: nil) },
            buttonActions: leoButtonActions
        )
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        action: { delegate?.performSplitAction($0) },
                        leafOverlay: { surface in
                            guard let leoSession, leoPlaceholderSurfaceIDs.contains(surface.id),
                                  let runtime = (NSApp.delegate as? AppDelegate)?.leoRuntime else { return nil }
                            return AnyView(LeoPlaceholderView(
                                model: runtime.model,
                                hostSelection: runtime.hostSelection,
                                shortcutHints: runtime.shortcutHints,
                                openPicker: { leoSession.openPicker(surfaceID: surface.id) },
                                buttonActions: leoButtonActions))
                        })
                        .environmentObject(ghostty)
                        .ghosttyLastFocusedSurface(lastFocusedSurface)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                                self.delegate?.focusedSurfaceDidChange(to: newValue)
                            }
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface?.value?.initialSize?.height)
        }
        // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
        .ignoresSafeArea(.container, edges: terminalIgnoredEdges)
    }

    // MARK: Leo

    /// In a Leo window, the same window-keyed edges as the sidebar split
    /// (B-074), so the terminal and the sidebar can't disagree
    /// after a config reload; upstream's live-config check otherwise.
    private var terminalIgnoredEdges: Edge.Set {
        guard leoSession == nil else { return leoSplitIgnoredEdges }
        return ghostty.config.macosTitlebarStyle == .hidden ? .top : []
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
