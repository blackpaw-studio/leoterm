# Leo — Phase 2c: Hover-Grow (Mode A, Elastic Reflow) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add hover-to-grow (the default "Mode A — elastic reflow"): hovering a cell makes it grow within the grid while its row/column neighbors squish, animated; when nothing is hovered, the **focused** cell stays grown. The growth geometry is pure math added to `GridLayout` (headlessly unit-tested); `TerminalGridView` drives it from `.onHover` and the focused surface.

**Architecture:** Extend `GridLayout` with an emphasis-aware `frames(in:gap:emphasizing:factor:)` that gives the emphasized cell's row extra height and its in-row column extra width (weighted distribution), with everything else shrinking to fit — total extent preserved (elastic reflow, no overflow). The existing `frames(in:gap:)` becomes a thin wrapper (emphasis = nil), so the 13 Phase-2a/2b tests stay valid. `TerminalGridView` tracks a hovered cell id (`@State`) and reads the focused surface (`@FocusedValue`); emphasized = hovered ?? focused; it animates frame changes.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Xcode 26.3 (`DEVELOPER_DIR`). Model logic verified by unit tests (headless); the hover feel is verified by Evan on a real display.

---

## Scope

**Phase 2c only** (spec §3, Mode A default). Delivers: emphasis geometry + hover/focus-driven grow with animation. **Out of scope (deferred):**
- Hover modes **B (magnify overlay)** and **C (hybrid)** — selectable later in 2e/config.
- **Debounced PTY resize.** In Mode A the surface receives a real new size as it grows, so its terminal reflows during the animation. The spec calls for debouncing this so the PTY only resizes once the hover settles. That requires changes in `SurfaceView`'s resize path and can only be feel-tested on a real display, so it is a **follow-up (2c-debounce)**: ship the straightforward grow first, let Evan judge whether the reflow is janky, then add debouncing if needed. This plan notes it explicitly rather than implementing it blind.
- Fixed/pinned cells (2d).

## Emphasis geometry (the spec to implement)

For `n` cells with `(rows, columns)` from `dimensions`, an emphasized cell at display index `e`, and growth `factor g (≥ 1)`:
- **Rows:** the emphasized cell's row gets weight `g`, other rows weight `1`; heights distribute by weight across the available height (minus gaps).
- **Columns (within a row):** only in the emphasized cell's row, its column gets weight `g`, others `1`; widths distribute by weight across the available width. Non-emphasized rows keep equal columns.
- **No emphasis** (`emphasizing: nil`, unknown id, or `factor ≤ 1`): all weights `1` → identical to the plain equal layout (last-row stretch preserved).
- Total extent is preserved: per row, Σ widths + gaps == size.width; Σ row heights + gaps == size.height.

## File / change map

- Modify: `macos/Sources/Features/Grid/GridLayout.swift` — add emphasis frame method + two private helpers; make plain `frames` delegate.
- Modify: `macos/Tests/Grid/GridLayoutTests.swift` — add emphasis tests.
- Modify: `macos/Sources/Features/Grid/TerminalGridView.swift` — hover/focus emphasis + animation.

## Commands (this environment)

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
# Unit tests (model):
cd /Users/evan/.leo/agents/leoterm/macos
xcodebuild test -scheme Ghostty -configuration Debug -packageAuthorizationProvider netrc -only-testing:GhosttyTests/GridLayoutTests 2>&1 | tail -20
# App build (view):
xcodebuild -target Ghostty -configuration Debug -packageAuthorizationProvider netrc build 2>&1 | tail -20
# Lint (MUST pass — the build runs it; aligned literals trip the comma rule):
swiftlint lint --strict --quiet 2>&1 | tail -20
```
Set Bash `timeout` to 600000 on build/test calls. **Run `swiftlint lint --strict --quiet` (from `macos/`) and fix all output before committing** — the Xcode build's SwiftLint phase fails on violations.

---

### Task 1: Emphasis-aware frame geometry (model, TDD)

**Files:**
- Modify: `macos/Sources/Features/Grid/GridLayout.swift`
- Modify: `macos/Tests/Grid/GridLayoutTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `GridLayoutTests`:
```swift
    @Test func emphasizingNilMatchesPlainFrames() {
        let cells = (0..<5).map { _ in MockCell() }
        let layout = GridLayout(cells: cells)
        let size = CGSize(width: 300, height: 200)
        let plain = layout.frames(in: size, gap: 4).map { $0.frame }
        let none = layout.frames(in: size, gap: 4, emphasizing: nil, factor: 1.6).map { $0.frame }
        #expect(plain == none)
    }

    @Test func factorOneIgnoresEmphasis() {
        let cells = (0..<4).map { _ in MockCell() }
        let layout = GridLayout(cells: cells)
        let size = CGSize(width: 200, height: 200)
        let plain = layout.frames(in: size).map { $0.frame }
        let emphasized = layout.frames(in: size, emphasizing: cells[0].id, factor: 1).map { $0.frame }
        #expect(plain == emphasized)
    }

    @Test func unknownEmphasisIdMatchesPlain() {
        let cells = (0..<4).map { _ in MockCell() }
        let layout = GridLayout(cells: cells)
        let size = CGSize(width: 200, height: 200)
        let plain = layout.frames(in: size).map { $0.frame }
        let bogus = layout.frames(in: size, emphasizing: UUID(), factor: 1.6).map { $0.frame }
        #expect(plain == bogus)
    }

    @Test func emphasizedCellIsLargerThanItsNeighbors() {
        // 2x2 grid, emphasize top-left (index 0).
        let cells = (0..<4).map { _ in MockCell() }
        let f = GridLayout(cells: cells)
            .frames(in: CGSize(width: 200, height: 200), emphasizing: cells[0].id, factor: 1.6)
            .map { $0.frame }
        #expect(f[0].width > f[1].width)    // wider than its row neighbor
        #expect(f[0].height > f[2].height)  // taller than its column neighbor
    }

    @Test func emphasisPreservesTotalExtent() {
        // 2x2 grid, gap 0: each row's widths sum to width, rows' heights sum to height.
        let cells = (0..<4).map { _ in MockCell() }
        let size = CGSize(width: 200, height: 200)
        let f = GridLayout(cells: cells).frames(in: size, emphasizing: cells[0].id, factor: 1.6)
            .map { $0.frame }
        let row0Width = f[0].width + f[1].width
        let col0Height = f[0].height + f[2].height
        #expect(abs(row0Width - size.width) < 0.001)
        #expect(abs(col0Height - size.height) < 0.001)
    }
```

- [ ] **Step 2: Run to verify failure**

Run the unit-test command. Expected: FAILS to compile (`frames(in:gap:emphasizing:factor:)` undefined).

- [ ] **Step 3: Implement emphasis geometry**

In `GridLayout.swift`, **replace** the existing `frames(in:gap:)` method with this delegating wrapper plus the emphasis method and helpers:
```swift
extension GridLayout {
    /// Equal auto-packed layout (no emphasis). See `frames(in:gap:emphasizing:factor:)`.
    func frames(in size: CGSize, gap: CGFloat = 0) -> [(cell: ViewType, frame: CGRect)] {
        frames(in: size, gap: gap, emphasizing: nil, factor: 1)
    }

    /// Frames with one cell emphasized (grown). The emphasized cell's row gets
    /// extra height and its in-row column gets extra width (weight `factor`),
    /// everything else shrinking to fit — total extent is preserved (elastic
    /// reflow, no overflow). `emphasizing: nil` / unknown id / `factor <= 1`
    /// yields the plain equal layout. Origin top-left.
    func frames(
        in size: CGSize,
        gap: CGFloat = 0,
        emphasizing emphasizedID: ViewType.ID?,
        factor: CGFloat
    ) -> [(cell: ViewType, frame: CGRect)] {
        let n = cells.count
        guard n > 0, size.width > 0, size.height > 0 else { return [] }
        let (rows, columns) = Self.dimensions(forCount: n)

        let emphasizedIndex = emphasizedID.flatMap { id in cells.firstIndex { $0.id == id } }
        let emphasizedRow = emphasizedIndex.map { $0 / columns }
        let g = max(1, factor)

        let rowWeights = (0..<rows).map { r in (r == emphasizedRow) ? g : 1 }
        let rowHeights = Self.distribute(total: size.height, gap: gap, weights: rowWeights)
        let rowOffsets = Self.offsets(of: rowHeights, gap: gap)

        var result: [(cell: ViewType, frame: CGRect)] = []
        result.reserveCapacity(n)
        for index in 0..<n {
            let row = index / columns
            let col = index % columns
            let isLastRow = row == rows - 1
            let cellsInRow = isLastRow ? (n - row * columns) : columns
            let emphasizedCol = (row == emphasizedRow) ? emphasizedIndex.map { $0 % columns } : nil
            let colWeights = (0..<cellsInRow).map { c in (c == emphasizedCol) ? g : 1 }
            let colWidths = Self.distribute(total: size.width, gap: gap, weights: colWeights)
            let colOffsets = Self.offsets(of: colWidths, gap: gap)
            result.append((cells[index], CGRect(
                x: colOffsets[col],
                y: rowOffsets[row],
                width: colWidths[col],
                height: rowHeights[row])))
        }
        return result
    }

    /// Distribute `total` (minus inter-cell `gap`s) across `weights` proportionally.
    private static func distribute(total: CGFloat, gap: CGFloat, weights: [CGFloat]) -> [CGFloat] {
        let count = weights.count
        guard count > 0 else { return [] }
        let available = total - gap * CGFloat(count - 1)
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 0, count: count) }
        return weights.map { available * ($0 / sum) }
    }

    /// Cumulative top-left offsets for consecutive `sizes` separated by `gap`.
    private static func offsets(of sizes: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        var accumulated: CGFloat = 0
        for size in sizes {
            result.append(accumulated)
            accumulated += size + gap
        }
        return result
    }
}
```
NOTE: delete the OLD `frames(in:gap:)` implementation (the one with the inline row/col loop from Phase 2a) so there's only the wrapper above — otherwise you'll have a duplicate method. Keep the `import CoreGraphics` line.

- [ ] **Step 4: Run to verify pass (new + all prior grid tests)**

Run the unit-test command. Expected: `** TEST SUCCEEDED **`, the 5 new emphasis tests AND all prior `GridLayoutTests` pass (the wrapper preserves old behavior).

- [ ] **Step 5: Lint, then commit**

```bash
cd /Users/evan/.leo/agents/leoterm/macos
swiftlint lint --strict --quiet 2>&1 | tail -20   # fix any output before committing
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/GridLayout.swift macos/Tests/Grid/GridLayoutTests.swift
git commit -m "feat(grid): emphasis-aware frame geometry for hover-grow"
```

---

### Task 2: Hover/focus-driven grow in `TerminalGridView` (view, build-verified)

**Files:**
- Modify: `macos/Sources/Features/Grid/TerminalGridView.swift`

- [ ] **Step 1: Add hover + focus emphasis with animation**

Replace the body of `TerminalGridView` so the grid emphasizes the hovered cell (or the focused surface when nothing is hovered) and animates changes. The full file should read:
```swift
import SwiftUI

/// Renders the window's terminal surfaces as an auto-arranging grid — Leo's
/// replacement for the binary `TerminalSplitTreeView`.
///
/// Phase 2c: dynamic auto-packing + click-to-focus + zoom + **hover-grow**
/// (Mode A elastic reflow). Hovering a cell grows it (neighbors squish); when
/// nothing is hovered, the focused cell stays grown. Modes B/C, fixed cells,
/// and debounced PTY resize come later.
struct TerminalGridView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    /// Gap between cells, in points. Made configurable in Phase 2e.
    private let gap: CGFloat = 4
    /// How much an emphasized cell grows relative to its neighbors.
    private let growthFactor: CGFloat = 1.6

    /// The cell currently under the pointer, if any.
    @State private var hoveredID: Ghostty.SurfaceView.ID?
    /// The focused surface (used as the emphasis target when nothing is hovered).
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    private struct PlacedCell: Identifiable {
        let id: Ghostty.SurfaceView.ID
        let surface: Ghostty.SurfaceView
        let frame: CGRect
    }

    var body: some View {
        if let zoomed = tree.zoomed, case .leaf(let surface) = zoomed {
            Ghostty.InspectableSurface(surfaceView: surface, isSplit: false)
        } else {
            grid
        }
    }

    private var grid: some View {
        let surfaces = Array(tree)
        let isSplit = surfaces.count > 1
        let emphasized = hoveredID ?? focusedSurface?.id
        return GeometryReader { geo in
            let placed = GridLayout(cells: surfaces)
                .frames(in: geo.size, gap: gap, emphasizing: emphasized, factor: growthFactor)
                .map { PlacedCell(id: $0.cell.id, surface: $0.cell, frame: $0.frame) }
            ZStack(alignment: .topLeading) {
                ForEach(placed) { item in
                    Ghostty.InspectableSurface(surfaceView: item.surface, isSplit: isSplit)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                        .onTapGesture { Ghostty.moveFocus(to: item.surface) }
                        .onHover { hovering in
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hoveredID)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: focusedSurface?.id)
        }
    }
}
```
If `growthFactor`/`gap` `private let` constants trigger a SwiftLint `identifier_name`/ordering issue, they won't (config min_length is 1). If the SwiftUI compiler complains the body is too complex, extract `placed`/`emphasized` exactly as shown (already split out) — do not change behavior.

- [ ] **Step 2: Build the app**

Run the app-build command. Expected: `** BUILD SUCCEEDED **`. If `@FocusedValue(\.ghosttySurfaceView)` doesn't resolve, confirm the key path name with `grep -rn "ghosttySurfaceView" macos/Sources` and use the exact one (it exists per the codebase; TerminalView.swift uses `@FocusedValue(\.ghosttySurfaceView)`).

- [ ] **Step 3: Lint, then commit**

```bash
cd /Users/evan/.leo/agents/leoterm/macos
swiftlint lint --strict --quiet 2>&1 | tail -20   # fix any output before committing
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/TerminalGridView.swift
git commit -m "feat(grid): hover-grow (Mode A elastic reflow) with focused-cell emphasis"
```

- [ ] **Step 4: Visual verification note (Evan, on a real display)**

Build can't confirm feel. Evan checks: hovering a cell grows it while neighbors squish (animated); moving the mouse away returns to even (or keeps the focused cell grown); clicking focuses and that cell stays grown. **Watch for reflow jank** (terminal content rapidly reflowing during the grow) — if present, that's the trigger for the deferred `2c-debounce` work.

---

## Self-Review

**Spec coverage (2c scope):** Mode A elastic reflow → `frames(in:gap:emphasizing:factor:)` (emphasized row taller, in-row column wider, neighbors squish, extent preserved). Hover drives it → `.onHover` → `hoveredID`. Focused cell stays grown → `emphasized = hoveredID ?? focusedSurface?.id`. Animated → `.animation(.spring…)`. Deferred (modes B/C, debounced resize, fixed cells) explicitly called out; debounce intentionally not built blind.

**Placeholder scan:** All code is concrete. Build-time symbol contingencies (FocusedValue key) include the exact grep to resolve. No vague steps.

**Type consistency:** New overload `frames(in:gap:emphasizing:factor:)` returns the same `[(cell: ViewType, frame: CGRect)]` shape; plain `frames(in:gap:)` delegates to it (preserving the 13 prior tests). `PlacedCell.id` is `Ghostty.SurfaceView.ID` (UUID), matching `hoveredID`/`emphasized`. `distribute`/`offsets` are `private static` helpers used only inside the emphasis method.

**Verification honesty:** Model behavior is unit-tested headlessly; the hover *feel* and the reflow-jank question are explicitly handed to Evan, not asserted.

**Next:** 2c-debounce (only if Evan reports jank), then Phase 2d — fixed/pinned cells (reserved tracks) + drag-to-resize.
