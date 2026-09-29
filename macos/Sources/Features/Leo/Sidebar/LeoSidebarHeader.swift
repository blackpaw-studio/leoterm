import SwiftUI

// MARK: - Layout probe

/// The measurable parts of the sidebar header.
enum LeoSidebarHeaderPart: Hashable {
    case title
    case accessory
}

/// Receives where a header part lands, in SwiftUI's global space (y down;
/// on macOS that includes the window's titlebar). A test seam: SwiftUI's accessibility
/// tree isn't reliably built inside the in-app test host, so layout tests
/// inject this through the environment instead. Nil (the default) in the app.
typealias LeoSidebarHeaderFrameSink = (LeoSidebarHeaderPart, CGRect) -> Void

private struct LeoSidebarHeaderFrameSinkKey: EnvironmentKey {
    static let defaultValue: LeoSidebarHeaderFrameSink? = nil
}

extension EnvironmentValues {
    var leoSidebarHeaderFrameSink: LeoSidebarHeaderFrameSink? {
        get { self[LeoSidebarHeaderFrameSinkKey.self] }
        set { self[LeoSidebarHeaderFrameSinkKey.self] = newValue }
    }
}

private struct LeoSidebarHeaderFrameReporter: ViewModifier {
    let part: LeoSidebarHeaderPart
    @Environment(\.leoSidebarHeaderFrameSink) private var sink

    func body(content: Content) -> some View {
        if let sink {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sink(part, $0) }
        } else {
            content
        }
    }
}

extension View {
    /// Reports this view's frame as `part` to the environment's
    /// `leoSidebarHeaderFrameSink`, when there is one.
    func leoSidebarHeaderFrame(_ part: LeoSidebarHeaderPart) -> some View {
        modifier(LeoSidebarHeaderFrameReporter(part: part))
    }
}
