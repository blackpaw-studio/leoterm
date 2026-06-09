# Leo — Phase 2d: Fixed/Pinned Cells (Reserved Row Track) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Let a cell be "pinned" to a fixed height by dragging its bottom edge — reserving its **row track** at that height while unpinned rows reflow to share the remaining height. Double-click the edge to unpin. Geometry lives in `GridLayout` (unit-tested); the drag handle lives in `TerminalGridView` (build-verified; feel-checked by Evan).

**Design decision (reserved track = row):** A single cell can't have a height independent of its grid row without a span-solver, so a pin fixes the **row** the cell occupies (the approved "reserved track" model). Pins are keyed by cell id and resolved to whatever row that cell currently occupies, so they survive add/remove. Multiple pins in one row → the max wins. Pins are session-only in 2d (persistence comes with boards later).

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Xcode 26.3 (`DEVELOPER_DIR`).

---

## Scope

**2d only:** pinned-row geometry in the model + drag-to-pin / double-click-to-unpin UI. Out of scope: column pinning, per-cell (non-row) independent sizing, pin persistence, config. Width emphasis (hover-grow) continues to work alongside pins.

## Geometry spec

Inputs: `n` cells, `(rows, columns)` from `dimensions`, `pinnedRowHeights: [ViewType.ID: CGFloat]`, plus existing emphasis (`emphasizedID`, `factor`).
- Map each pin to the row of its cell (`index/columns`). A row's pinned height = max pin among its cells, else unpinned.
- Reserved height = Σ pinned-row heights. Remaining = `size.height − reserved − gaps`. Distribute remaining among **unpinned** rows by weight (emphasized unpinned row = `factor`, others `1`). If remaining < 0, unpinned rows get 0 (clamp).
- Column widths within each row unchanged (emphasis-aware), per Phase 2c.
- `pinnedRowHeights` empty → identical to the Phase 2c result (preserves all prior tests).

## Files

- Modify: `macos/Sources/Features/Grid/GridLayout.swift` — add a pinned-row-aware frames overload; make the 2c overload delegate.
- Modify: `macos/Tests/Grid/GridLayoutTests.swift` — pinned-row tests.
- Modify: `macos/Sources/Features/Grid/TerminalGridView.swift` — `@State pinnedRowHeights`, a bottom drag handle per cell, double-click unpin.

## Commands

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd /Users/evan/.leo/agents/leoterm/macos
xcodebuild test -scheme Ghostty -configuration Debug -packageAuthorizationProvider netrc -only-testing:GhosttyTests/GridLayoutTests 2>&1 | tail -20
xcodebuild -target Ghostty -configuration Debug -packageAuthorizationProvider netrc build 2>&1 | tail -20
swiftlint lint --strict --quiet   # MUST be empty before commit
```
Bash `timeout` 600000 on build/test.

---

### Task 1: Pinned-row geometry (model, TDD)

- [ ] **Step 1 — failing tests** (add to `GridLayoutTests`):
```swift
    @Test func emptyPinsMatchesEmphasisFrames() {
        let cells = (0..<4).map { _ in MockCell() }
        let layout = GridLayout(cells: cells)
        let size = CGSize(width: 200, height: 200)
        let a = layout.frames(in: size, emphasizing: cells[0].id, factor: 1.6).map { $0.frame }
        let b = layout.frames(in: size, gap: 0, pinnedRowHeights: [:],
                              emphasizing: cells[0].id, factor: 1.6).map { $0.frame }
        #expect(a == b)
    }

    @Test func pinnedRowGetsItsExactHeight() {
        // 4 cells -> 2x2. Pin row 0 (cell 0) to 60 of 200 tall; row 1 gets remaining 140.
        let cells = (0..<4).map { _ in MockCell() }
        let f = GridLayout(cells: cells).frames(
            in: CGSize(width: 200, height: 200), gap: 0,
            pinnedRowHeights: [cells[0].id: 60], emphasizing: nil, factor: 1).map { $0.frame }
        #expect(abs(f[0].height - 60) < 0.001)   // row 0
        #expect(abs(f[1].height - 60) < 0.001)   // same row
        #expect(abs(f[2].height - 140) < 0.001)  // row 1 remainder
        #expect(abs(f[3].height - 140) < 0.001)
    }

    @Test func pinnedRowHeightSurvivesAcrossMultipleUnpinnedRows() {
        // 6 cells -> 2x3. Pin row 0 to 50 of 200; row 1 gets 150.
        let cells = (0..<6).map { _ in MockCell() }
        let f = GridLayout(cells: cells).frames(
            in: CGSize(width: 300, height: 200), gap: 0,
            pinnedRowHeights: [cells[1].id: 50], emphasizing: nil, factor: 1).map { $0.frame }
        #expect(abs(f[0].height - 50) < 0.001)
        #expect(abs(f[3].height - 150) < 0.001)
    }
```
- [ ] **Step 2 — run, expect compile failure** (new overload undefined).
- [ ] **Step 3 — implement.** In `GridLayout.swift`, change the Phase-2c emphasis method to delegate, and add the pinned overload. Replace the existing `frames(in:gap:emphasizing:factor:)` body so it calls the new one with empty pins:
```swift
    func frames(
        in size: CGSize,
        gap: CGFloat = 0,
        emphasizing emphasizedID: ViewType.ID?,
        factor: CGFloat
    ) -> [(cell: ViewType, frame: CGRect)] {
        frames(in: size, gap: gap, pinnedRowHeights: [:], emphasizing: emphasizedID, factor: factor)
    }

    /// Frames with optional per-row pinning. A row containing a cell present in
    /// `pinnedRowHeights` is fixed to that height (max if several); remaining
    /// height is shared by unpinned rows (emphasized unpinned row weight `factor`).
    /// Empty pins → identical to the emphasis-only layout.
    func frames(
        in size: CGSize,
        gap: CGFloat = 0,
        pinnedRowHeights: [ViewType.ID: CGFloat],
        emphasizing emphasizedID: ViewType.ID?,
        factor: CGFloat
    ) -> [(cell: ViewType, frame: CGRect)] {
        let n = cells.count
        guard n > 0, size.width > 0, size.height > 0 else { return [] }
        let (rows, columns) = Self.dimensions(forCount: n)

        let emphasizedIndex = emphasizedID.flatMap { id in cells.firstIndex { $0.id == id } }
        let emphasizedRow = emphasizedIndex.map { $0 / columns }
        let g = max(1, factor)

        // Resolve pinned height per row (max pin among the row's cells).
        var pinnedHeightForRow = [Int: CGFloat]()
        for (index, cell) in cells.enumerated() {
            if let h = pinnedRowHeights[cell.id] {
                let row = index / columns
                pinnedHeightForRow[row] = max(pinnedHeightForRow[row] ?? 0, h)
            }
        }

        let rowHeights = Self.distributeWithFixed(
            total: size.height, gap: gap, count: rows,
            fixed: pinnedHeightForRow,
            flexWeight: { r in (r == emphasizedRow && pinnedHeightForRow[r] == nil) ? g : 1 })
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
                x: colOffsets[col], y: rowOffsets[row],
                width: colWidths[col], height: rowHeights[row])))
        }
        return result
    }

    /// Distribute `total` across `count` slots: slots in `fixed` take their fixed
    /// size; the rest share the remainder (minus gaps) by `flexWeight`. Remainder
    /// is clamped at 0.
    private static func distributeWithFixed(
        total: CGFloat, gap: CGFloat, count: Int,
        fixed: [Int: CGFloat], flexWeight: (Int) -> CGFloat
    ) -> [CGFloat] {
        guard count > 0 else { return [] }
        let gaps = gap * CGFloat(count - 1)
        let fixedTotal = fixed.values.reduce(0, +)
        let remaining = max(0, total - gaps - fixedTotal)
        let flexIndices = (0..<count).filter { fixed[$0] == nil }
        let weightSum = flexIndices.reduce(0) { $0 + flexWeight($1) }
        return (0..<count).map { i in
            if let f = fixed[i] { return f }
            guard weightSum > 0 else { return 0 }
            return remaining * (flexWeight(i) / weightSum)
        }
    }
```
Keep the existing `distribute(total:gap:weights:)` and `offsets(of:gap:)` helpers.
- [ ] **Step 4 — run tests, expect ALL pass** (new + all prior).
- [ ] **Step 5 — lint clean, commit:**
```bash
cd /Users/evan/.leo/agents/leoterm/macos && swiftlint lint --strict --quiet 2>&1 | tail -10
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/GridLayout.swift macos/Tests/Grid/GridLayoutTests.swift
git commit -m "feat(grid): pinned-row (reserved track) geometry"
```

---

### Task 2: Drag-to-pin handle in the view (build-verified)

- [ ] **Step 1 — add pin state + drag handle.** In `TerminalGridView.swift`: add `@State private var pinnedRowHeights: [Ghostty.SurfaceView.ID: CGFloat] = [:]`; pass it to the frames call (`pinnedRowHeights: pinnedRowHeights, emphasizing: emphasized, factor: growthFactor`); and overlay a bottom drag handle per cell. Concretely, replace the `grid` computed property with:
```swift
    private var grid: some View {
        let surfaces = Array(tree)
        let isSplit = surfaces.count > 1
        let emphasized = hoveredID ?? focusedSurface?.id
        return GeometryReader { geo in
            let placed = GridLayout(cells: surfaces)
                .frames(in: geo.size, gap: gap, pinnedRowHeights: pinnedRowHeights,
                        emphasizing: emphasized, factor: growthFactor)
                .map { PlacedCell(id: $0.cell.id, surface: $0.cell, frame: $0.frame) }
            ZStack(alignment: .topLeading) {
                ForEach(placed) { item in
                    Ghostty.InspectableSurface(surfaceView: item.surface, isSplit: isSplit)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .overlay(alignment: .bottom) { pinHandle(for: item) }
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                        .onTapGesture { Ghostty.moveFocus(to: item.surface) }
                        .onHover { hovering in
                            if hovering { hoveredID = item.id }
                            else if hoveredID == item.id { hoveredID = nil }
                        }
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hoveredID)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: focusedSurface?.id)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pinnedRowHeights)
        }
    }

    /// A thin grab strip along a cell's bottom edge: drag to pin the row height,
    /// double-click to unpin.
    private func pinHandle(for item: PlacedCell) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(pinnedRowHeights[item.id] != nil ? 0.5 : 0.001))
            .frame(height: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let newHeight = max(40, item.frame.height + value.translation.height)
                        pinnedRowHeights[item.id] = newHeight
                    }
            )
            .onTapGesture(count: 2) { pinnedRowHeights[item.id] = nil }
            .help(pinnedRowHeights[item.id] != nil
                  ? "Pinned row — drag to resize, double-click to unpin"
                  : "Drag to pin this row's height")
    }
```
- [ ] **Step 2 — build app**, expect `** BUILD SUCCEEDED **`. If the double `.frame` before/after `.overlay` causes layout issues at compile time it won't (it compiles); keep as written so the overlay sizes to the cell.
- [ ] **Step 3 — lint clean, commit:**
```bash
cd /Users/evan/.leo/agents/leoterm/macos && swiftlint lint --strict --quiet 2>&1 | tail -10
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/TerminalGridView.swift
git commit -m "feat(grid): drag-to-pin row height (reserved track) with double-click unpin"
```
- [ ] **Step 4 — Evan visual note:** drag a cell's bottom edge → its row keeps that height while other rows reflow; double-click the strip → unpins. (Strip is near-invisible until pinned.)

---

## Self-Review

**Coverage:** reserved-row geometry → `frames(…pinnedRowHeights:…)` + `distributeWithFixed`; drag-to-pin/unpin → `pinHandle`. Empty pins preserve all prior tests (delegation). Hover emphasis still applies to unpinned rows + within-row widths.

**Placeholders:** none — full code given. **Consistency:** new overload returns same tuple shape; 2c overload delegates with `[:]`; `pinnedRowHeights` typed `[Ghostty.SurfaceView.ID: CGFloat]` in the view matches the model key type.

**Honesty:** model unit-tested headlessly; drag *feel* and the row-track interpretation are flagged for Evan. **Next:** 2e — new-plain-terminal-cell action, then retire the split UI; Leo config (gap/factor/hover-mode) once worth wiring through the C config.
