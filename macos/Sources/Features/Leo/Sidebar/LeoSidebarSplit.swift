import SwiftUI

enum LeoSidebarSplitMetrics {
    static let minimumWidth: CGFloat = 200
    static let maximumWidth: CGFloat = 420
    static let minimumTerminalWidth: CGFloat = 30
    static let dividerWidth: CGFloat = 6

    static func width(preferred: CGFloat, available: CGFloat) -> CGFloat {
        let upperBound = max(minimumWidth, min(maximumWidth, available - minimumTerminalWidth - dividerWidth))
        return min(max(preferred, minimumWidth), upperBound)
    }
}

struct LeoSidebarSplit<Terminal: View>: View {
    @ObservedObject var session: LeoWindowSession
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions
    private let terminal: Terminal

    @State private var dragOrigin: CGFloat?

    init(session: LeoWindowSession, model: LeoSidebarModel, actions: LeoAgentActions, @ViewBuilder terminal: () -> Terminal) {
        self.session = session
        self.model = model
        self.actions = actions
        self.terminal = terminal()
    }

    var body: some View {
        GeometryReader { geometry in
            let width = LeoSidebarSplitMetrics.width(
                preferred: session.preferredWidth,
                available: geometry.size.width
            )
            HStack(spacing: 0) {
                LeoSidebarView(model: model, windowID: session.id, actions: actions)
                    .frame(width: session.isSidebarVisible ? width : 0)
                    .clipped()
                    .opacity(session.isSidebarVisible ? 1 : 0)
                    .accessibilityHidden(!session.isSidebarVisible)

                divider(width: width)
                    .frame(width: session.isSidebarVisible ? LeoSidebarSplitMetrics.dividerWidth : 0)
                    .clipped()

                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -3))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let origin = dragOrigin ?? width
                    if dragOrigin == nil { dragOrigin = width }
                    session.setPreferredWidth(origin + value.translation.width)
                }
                .onEnded { _ in dragOrigin = nil })
            .accessibilityElement()
            .accessibilityLabel("Agents sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 20 : -20
                session.setPreferredWidth(width + delta)
            }
    }
}
