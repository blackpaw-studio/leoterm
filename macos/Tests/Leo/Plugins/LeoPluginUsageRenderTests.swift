import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// Plan Step 15: the usage plugin's real render trees (Lane B's fixtures),
/// drawn offscreen in light and dark at the sidebar's default width and the
/// palette's width. Asserts nothing clips (valueText never truncates, Groups
/// get their fitting height, tracks share one column) and writes PNGs to
/// `$TMPDIR/leo-usage-renders` for a look.
@MainActor @Suite(.serialized)
struct LeoPluginUsageRenderTests {
    static let sidebarWidth: CGFloat = 260
    /// `CommandPalette`'s `maxWidth`.
    static let paletteWidth: CGFloat = 500
    static let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    /// Auto Layout and text measurement round to half points.
    static let layoutRounding: CGFloat = 0.5

    // MARK: Full view (pane / palette body)

    @Test(arguments: [sidebarWidth, paletteWidth])
    func theFullViewFitsWithoutClippingAndLinesUpItsTracks(width: CGFloat) throws {
        let nodes = try Self.fixture("full")
        for (name, appearance) in Self.appearances {
            let canvas = Self.canvas(width: width, appearance: appearance)
            let body = LeoPluginNodeView(emitter: LeoPluginActionEmitter(mint: LeoPluginGestureMint(), handler: { _, _ in }))
            var preferred: CGFloat?
            body.onPreferredHeightChange = { preferred = $0 }
            canvas.host(body, height: 1600)
            body.render(nodes)
            canvas.layout()
            canvas.resize(height: (preferred ?? 1600).rounded(.up))

            let meters = Self.views(LeoPluginValueMeterView.self, in: body)
            let groups = Self.views(LeoPluginGroupView.self, in: body)
            try #require(groups.count == 4 && meters.count == 7, "fixture: 4 Groups and 7 meters; drew \(groups.count) and \(meters.count)")
            for meter in meters {
                #expect(!meter.isValueTextTruncated, "\(meter.meter.label) valueText truncated at \(width) pt, \(name)")
            }
            for group in groups {
                #expect(group.frame.height + Self.layoutRounding >= group.fittingSize.height, "\(group.group.title) clipped at \(width) pt, \(name)")
                #expect(group.frame.width <= width + Self.layoutRounding)
            }
            let trackStarts = meters.map { $0.label.convert($0.label.bounds, to: nil).maxX }
            #expect((trackStarts.max() ?? 0) - (trackStarts.min() ?? 0) <= Self.layoutRounding, "tracks don't line up: \(trackStarts)")
            try canvas.writePNG(named: "full-\(Int(width))-\(name)")
        }
    }

    // MARK: Sidebar section

    @Test func theSidebarSectionDrawsItsHeaderAccessoryOpenAndCollapsed() async throws {
        let nodes = try Self.fixture("sidebar")
        let layout = LeoPluginSectionRows.layout(from: nodes)
        let accessory = try #require(layout.headerAccessory, "the sidebar fixture leads with the worst-usage accessory")
        for (name, appearance) in Self.appearances {
            let canvas = Self.canvas(width: Self.sidebarWidth, appearance: appearance)
            let hosting = NSHostingView(rootView: Self.sidebar(nodes: nodes, accessory: accessory))
            canvas.host(hosting, height: 520)
            let table = try await Self.settledTable(in: canvas.window, minimumRows: 3)
            #expect(table.frame.width <= Self.sidebarWidth + Self.layoutRounding)
            try canvas.writePNG(named: "sidebar-\(Int(Self.sidebarWidth))-\(name)")
        }
    }

    /// The compact meter row's columns at every sidebar width down to the
    /// narrowest: valueText always gets its full width, the label column never
    /// passes 40%, and the track keeps its minimum while there is room.
    @Test func compactMeterColumnsNeverTruncateValueText() throws {
        let rows = LeoPluginSectionRows.layout(from: try Self.fixture("sidebar")).rows
        let column = LeoPluginSectionMeter.labelColumn(for: rows)
        let meters = rows.flatMap { row -> [LeoPluginNode.ValueMeter] in
            switch row {
            case .group(_, let group): group.children.compactMap(Self.meter)
            case .meter(_, let meter): [meter]
            default: []
            }
        }
        try #require(!meters.isEmpty)
        let minimumTrack: CGFloat = 48
        for meter in meters {
            let presentation = LeoPluginValueMeterPresentation(meter)
            let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: presentation.emphasizesValueText ? .semibold : .regular)
            let value = ceil(((meter.valueText ?? "") as NSString).size(withAttributes: [.font: valueFont]).width)
            for width in stride(from: CGFloat(100), through: Self.paletteWidth, by: 10) {
                let columns = LeoPluginMeterRowLayout.columns(
                    width: width, labelIdeal: column ?? 0, labelColumn: column, value: value, minimumTrackWidth: minimumTrack)
                #expect(columns.value == value, "\(meter.label) at \(width)")
                #expect(columns.label <= width * 0.4 + Self.layoutRounding)
                if width >= value + 16 + minimumTrack { #expect(columns.track + Self.layoutRounding >= minimumTrack, "\(meter.label) at \(width)") }
                #expect(columns.label + columns.track + columns.value + 16 <= width + Self.layoutRounding)
            }
        }
    }

    // MARK: Harness

    private static func sidebar(nodes: [LeoPluginNode], accessory: LeoPluginNode.Accessory) -> some View {
        let open = LeoPluginSidebarSectionEntry(pluginID: "studio.blackpaw.usage", pluginName: "Account Usage", sectionID: "usage", title: "Usage")
        let closed = LeoPluginSidebarSectionEntry(pluginID: "studio.blackpaw.usage", pluginName: "Account Usage", sectionID: "usage2", title: "Usage")
        return List {
            Section(header: LeoPluginSectionHeader(entry: closed, expanded: false, accessory: accessory, toggle: {}, hide: {})) {
                Color.clear.frame(height: 1).listRowInsets(EdgeInsets())
            }
            Section(header: LeoPluginSectionHeader(entry: open, expanded: true, accessory: accessory, toggle: {}, hide: {})) {
                LeoPluginSectionNodeRows(nodes: nodes) { _ in }
            }
        }
        .listStyle(.sidebar)
        .frame(width: sidebarWidth)
    }

    static func fixture(_ name: String) throws -> [LeoPluginNode] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("plugins/usage/test/fixtures/trees/\(name).json")
        let decoder = JSONDecoder()
        decoder.userInfo[LeoPluginNodeDecoding.apiVersionKey] = 2
        return try decoder.decode(LeoPluginSlotRoot.self, from: Data(contentsOf: url)).nodes
    }

    static func meter(_ child: LeoPluginNode.Group.Child) -> LeoPluginNode.ValueMeter? {
        if case .meter(let meter) = child { meter } else { nil }
    }

    static func canvas(width: CGFloat, appearance: NSAppearance.Name) -> RenderCanvas {
        RenderCanvas(width: width, appearance: NSAppearance(named: appearance))
    }

    static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// Waits for the sidebar List's table to fill in and stop moving.
    private static func settledTable(in window: NSWindow, minimumRows: Int) async throws -> NSTableView {
        let deadline = ContinuousClock.now + .seconds(5)
        var previous: [NSRect]?
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let table = views(NSTableView.self, in: window.contentView).first, table.numberOfRows >= minimumRows {
                let measured = (0..<table.numberOfRows).map { table.rect(ofRow: $0) }
                if measured == previous { return table }
                previous = measured
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(views(NSTableView.self, in: window.contentView).first, "the sidebar List never laid out")
    }
}

/// An offscreen window with an opaque window-background canvas, so PNGs show
/// what the user would see on a plain window. The width is required, like a
/// real slot's: a window's own size holds only at priority 500, so without
/// this any 500+ preference (a shared label column) would widen the canvas.
@MainActor final class RenderCanvas {
    let window: NSWindow
    private let container = NSView()
    private let width: CGFloat

    init(width: CGFloat, appearance: NSAppearance?) {
        self.width = width
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        container.wantsLayer = true
        window.contentView = container
        container.appearance = appearance
    }

    func host(_ view: NSView, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        resize(height: height)
    }

    func resize(height: CGFloat) {
        window.setContentSize(NSSize(width: width, height: height))
        layout()
    }

    func layout() {
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
    }

    func writePNG(named name: String) throws {
        layout()
        let bounds = container.bounds
        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: bounds))
        container.cacheDisplay(in: bounds, to: rep)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leo-usage-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }

    deinit { MainActor.assumeIsolated { window.close() } }
}
