import SwiftUI

/// The sidebar chrome's spacing, in one place so every strip of chrome
/// (above the list: this header, the host picker, the search field; below
/// it: B-065's footer button bar) keeps the same rhythm. Modelled on the macOS 26 Mail and Finder
/// sidebars: the first control clears the titlebar by about the same gap
/// that separates the controls from each other, and nothing touches the
/// sidebar's edges.
enum LeoSidebarChromeMetrics {
    /// From the titlebar's bottom edge to the first row of chrome.
    static let topInset: CGFloat = 10
    /// From the sidebar's leading and trailing edges to its chrome.
    static let horizontalInset: CGFloat = 10
    /// Between stacked rows of chrome, and below the last one.
    static let itemSpacing: CGFloat = 10
    /// The least room between a header's title and its trailing accessory.
    static let titleAccessoryMinSpacing: CGFloat = 8
}

/// A sidebar header row: a title on the leading edge and an accessory
/// (typically a borderless button) on the trailing edge, on one line.
struct LeoSidebarHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .leoSidebarHeaderFrame(.title)
            Spacer(minLength: LeoSidebarChromeMetrics.titleAccessoryMinSpacing)
            accessory
                .leoSidebarHeaderFrame(.accessory)
        }
    }
}

// MARK: - Layout probe

/// The measurable parts of the sidebar's chrome.
enum LeoSidebarHeaderPart: Hashable {
    case title
    case accessory
    case searchField
    /// The footer button bar (B-065), below the list.
    case buttonBar
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
