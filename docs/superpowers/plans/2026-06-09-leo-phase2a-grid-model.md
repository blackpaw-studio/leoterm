# Leo — Phase 2a: Grid Layout Model & Auto-Packing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `GridLayout` — an immutable value type that models an auto-arranging grid of terminal cells and computes each cell's frame — with full Swift Testing unit coverage. This is pure model/geometry logic with **no UI**, so it is verifiable headlessly (important: the GUI cannot be visually verified from the build environment).

**Architecture:** A generic immutable `GridLayout<ViewType: Identifiable>` holding cells in display order, plus auto-packing math (`dimensions`) and frame computation (`frames`). It lives alongside Ghostty's existing `SplitTree` and reuses the same conventions (generic over an `Identifiable` view type, immutable "returns a new copy" mutation methods, Swift Testing with a mock view). Later Phase 2 sub-plans render this model (`TerminalGridView`), wire it into `BaseTerminalController`, add hover-grow, fixed/pinned cells, and remove the split UI.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`, `@Test`, `#expect`), Xcode 26.3 (`DEVELOPER_DIR`), the `Ghostty` app target + `GhosttyTests` test target (filesystem-synchronized groups — new files auto-include).

---

## Scope

**Phase 2a only.** From `docs/superpowers/specs/2026-06-08-leo-terminal-design.md` §2–3, this delivers the grid **data model and packing geometry** for **dynamic cells** (the default). Explicitly **out of scope** here (later sub-plans):

- 2b: `TerminalGridView` SwiftUI rendering of the model.
- 2c: hover-grow (mode A) + sticky click-to-focus interaction.
- 2d: fixed/pinned cells (reserved-track sizing) and drag-to-resize.
- 2e: plain-terminal "new cell" action, `leo` config options, removal of the split UI.

Keeping 2a to model+geometry means it is **fully unit-testable without a display**, giving a verified foundation before any UI work.

## Packing rule (the core spec to implement)

For `n` cells, the grid is square-ish, **biased wider** (columns ≥ rows):

```
rows    = floor(sqrt(n))        (min 1 for n ≥ 1)
columns = ceil(n / rows)
```

This reproduces the approved mockup:

| n | rows × columns |
|---|----------------|
| 1 | 1 × 1 |
| 2 | 1 × 2 |
| 3 | 1 × 3 |
| 4 | 2 × 2 |
| 5 | 2 × 3 |
| 6 | 2 × 3 |
| 7 | 2 × 4 |
| 8 | 2 × 4 |
| 9 | 3 × 3 |
| 10 | 3 × 4 |

Cells fill **row-major** (left→right, top→bottom). Rows split height equally. Within a row, cells split that row's width equally; the **last (possibly partial) row stretches its cells across the full width**. Frames use a **top-left origin** (y grows downward); the renderer maps to its own coordinate space later.

## File / change map

- Create: `macos/Sources/Features/Grid/GridLayout.swift` — the model (auto-included in `Ghostty` target via synchronized group).
- Create: `macos/Tests/Grid/GridLayoutTests.swift` — Swift Testing unit tests (auto-included in `GhosttyTests` target).
- No existing files modified in 2a.

## Build/test commands (this environment)

Always set the toolchain (Xcode 26.5's SDK breaks Zig; see `LEO.md`):
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
```
Run the unit tests (headless-safe; `-packageAuthorizationProvider netrc` avoids a Keychain hang on Sparkle):
```bash
cd /Users/evan/.leo/agents/leoterm/macos
xcodebuild test -scheme Ghostty -configuration Debug \
  -packageAuthorizationProvider netrc \
  -only-testing:GhosttyTests/GridLayoutTests 2>&1 | tail -30
```
First build may take several minutes — set the Bash tool `timeout` to 600000 on build/test calls.

---

### Task 1: Scaffold the type and prove the headless test harness

Goal: create the file in the synchronized group, confirm it compiles into the target, and confirm one Swift Testing test runs headlessly — before writing real logic. This de-risks file-inclusion and headless test execution.

**Files:**
- Create: `macos/Sources/Features/Grid/GridLayout.swift`
- Create: `macos/Tests/Grid/GridLayoutTests.swift`

- [ ] **Step 1: Create the model skeleton**

Create `macos/Sources/Features/Grid/GridLayout.swift`:
```swift
import Foundation

/// An immutable model of an auto-arranging grid of cells.
///
/// Phase 2a models **dynamic** cells only: cells are auto-packed into a
/// square-ish, width-biased grid. Fixed/pinned cells arrive in a later phase.
///
/// Generic over an `Identifiable` view type so it can be unit-tested with a
/// mock and used with `Ghostty.SurfaceView` in the app. Mutation methods follow
/// the codebase convention of returning a new copy (see `SplitTree`).
struct GridLayout<ViewType: Identifiable> {
    /// Cells in display order: row-major, left→right, top→bottom.
    private(set) var cells: [ViewType]

    init(cells: [ViewType] = []) {
        self.cells = cells
    }
}
```

- [ ] **Step 2: Create the test file with a mock view and one trivial test**

Create `macos/Tests/Grid/GridLayoutTests.swift`:
```swift
import Testing
import Foundation
@testable import Ghostty

/// Minimal Identifiable stand-in for a cell, mirroring the MockView pattern
/// used by SplitTreeTests.
private struct MockCell: Identifiable, Equatable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

struct GridLayoutTests {
    @Test func emptyLayoutHasNoCells() {
        let layout = GridLayout<MockCell>()
        #expect(layout.cells.isEmpty)
    }
}
```

- [ ] **Step 3: Run the test (proves inclusion + headless run)**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd /Users/evan/.leo/agents/leoterm/macos
xcodebuild test -scheme Ghostty -configuration Debug -packageAuthorizationProvider netrc -only-testing:GhosttyTests/GridLayoutTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` and the `emptyLayoutHasNoCells` test passing. If the test isn't found/compiled, the synchronized group didn't pick up the new files — STOP and report BLOCKED (the file may need manual addition to the target in `project.pbxproj`).

- [ ] **Step 4: Commit**

```bash
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/GridLayout.swift macos/Tests/Grid/GridLayoutTests.swift
git commit -m "feat(grid): scaffold GridLayout model with passing test harness"
```

---

### Task 2: Cell collection operations (count, contains, append, remove)

**Files:**
- Modify: `macos/Sources/Features/Grid/GridLayout.swift`
- Modify: `macos/Tests/Grid/GridLayoutTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `GridLayoutTests` (inside the struct):
```swift
    @Test func countAndIsEmpty() {
        #expect(GridLayout<MockCell>().isEmpty)
        let layout = GridLayout(cells: [MockCell(), MockCell()])
        #expect(layout.count == 2)
        #expect(!layout.isEmpty)
    }

    @Test func appendingReturnsNewLayoutAndLeavesOriginalUnchanged() {
        let original = GridLayout<MockCell>()
        let cell = MockCell()
        let updated = original.appending(cell)
        #expect(original.isEmpty)                 // immutability
        #expect(updated.count == 1)
        #expect(updated.contains(id: cell.id))
    }

    @Test func removingByIdDropsOnlyThatCell() {
        let keep = MockCell()
        let drop = MockCell()
        let layout = GridLayout(cells: [keep, drop]).removing(id: drop.id)
        #expect(layout.count == 1)
        #expect(layout.contains(id: keep.id))
        #expect(!layout.contains(id: drop.id))
    }
```

- [ ] **Step 2: Run to verify failure**

Run the Task 2 test command (see header). Expected: FAILS to compile (`count`, `isEmpty`, `appending`, `contains`, `removing` undefined).

- [ ] **Step 3: Implement the operations**

Add to `GridLayout.swift`:
```swift
extension GridLayout {
    var count: Int { cells.count }
    var isEmpty: Bool { cells.isEmpty }

    func contains(id: ViewType.ID) -> Bool {
        cells.contains { $0.id == id }
    }

    /// Returns a new layout with `cell` appended at the end (display order).
    func appending(_ cell: ViewType) -> Self {
        GridLayout(cells: cells + [cell])
    }

    /// Returns a new layout with the cell matching `id` removed (if present).
    func removing(id: ViewType.ID) -> Self {
        GridLayout(cells: cells.filter { $0.id != id })
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run the test command. Expected: `** TEST SUCCEEDED **`, all collection tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Grid/GridLayout.swift macos/Tests/Grid/GridLayoutTests.swift
git commit -m "feat(grid): cell collection ops (count, contains, append, remove)"
```

---

### Task 3: Auto-packing dimensions

**Files:**
- Modify: `macos/Sources/Features/Grid/GridLayout.swift`
- Modify: `macos/Tests/Grid/GridLayoutTests.swift`

- [ ] **Step 1: Write failing tests (the full packing table)**

Add to `GridLayoutTests`:
```swift
    @Test(arguments: [
        (0, 0, 0), (1, 1, 1), (2, 1, 2), (3, 1, 3), (4, 2, 2),
        (5, 2, 3), (6, 2, 3), (7, 2, 4), (8, 2, 4), (9, 3, 3), (10, 3, 4),
    ])
    func dimensionsMatchPackingTable(n: Int, rows: Int, columns: Int) {
        let dims = GridLayout<MockCell>.dimensions(forCount: n)
        #expect(dims.rows == rows)
        #expect(dims.columns == columns)
    }

    @Test func dimensionsAreNeverTallerThanWide() {
        for n in 1...50 {
            let d = GridLayout<MockCell>.dimensions(forCount: n)
            #expect(d.columns >= d.rows)            // width-biased
            #expect(d.rows * d.columns >= n)        // enough slots
        }
    }

    @Test func instanceDimensionsTrackCellCount() {
        let layout = GridLayout(cells: (0..<6).map { _ in MockCell() })
        let d = layout.dimensions
        #expect(d.rows == 2 && d.columns == 3)
    }
```

- [ ] **Step 2: Run to verify failure**

Run the test command. Expected: FAILS to compile (`dimensions` undefined).

- [ ] **Step 3: Implement dimensions**

Add to `GridLayout.swift`:
```swift
extension GridLayout {
    /// (rows, columns) for `n` cells: square-ish, biased wider (columns ≥ rows).
    /// rows = floor(sqrt(n)) (min 1); columns = ceil(n / rows). Zero for n ≤ 0.
    static func dimensions(forCount n: Int) -> (rows: Int, columns: Int) {
        guard n > 0 else { return (0, 0) }
        let rows = max(1, Int(Double(n).squareRoot().rounded(.down)))
        let columns = Int((Double(n) / Double(rows)).rounded(.up))
        return (rows, columns)
    }

    /// (rows, columns) for the current cell count.
    var dimensions: (rows: Int, columns: Int) { Self.dimensions(forCount: count) }
}
```

- [ ] **Step 4: Run to verify pass**

Run the test command. Expected: `** TEST SUCCEEDED **`, all dimension tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Grid/GridLayout.swift macos/Tests/Grid/GridLayoutTests.swift
git commit -m "feat(grid): square-ish width-biased auto-packing dimensions"
```

---

### Task 4: Frame computation (row-major, last-row stretch)

**Files:**
- Modify: `macos/Sources/Features/Grid/GridLayout.swift`
- Modify: `macos/Tests/Grid/GridLayoutTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `GridLayoutTests`:
```swift
    @Test func framesEmptyOrZeroSizeReturnsNothing() {
        #expect(GridLayout<MockCell>().frames(in: CGSize(width: 100, height: 100)).isEmpty)
        let one = GridLayout(cells: [MockCell()])
        #expect(one.frames(in: .zero).isEmpty)
    }

    @Test func framesSingleCellFillsBounds() {
        let cell = MockCell()
        let frames = GridLayout(cells: [cell]).frames(in: CGSize(width: 800, height: 600))
        #expect(frames.count == 1)
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func framesThreeCellsAreOneRowOfEqualThirds() {
        let cells = (0..<3).map { _ in MockCell() }
        let frames = GridLayout(cells: cells).frames(in: CGSize(width: 300, height: 100))
        #expect(frames.count == 3)
        // 1 row of 3 → each 100 wide, full height, no overlap.
        #expect(frames.map { $0.frame } == [
            CGRect(x: 0,   y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ])
    }

    @Test func framesLastPartialRowStretchesAcrossFullWidth() {
        // n=5 → rows=2, columns=3. Row 0: 3 cells (100 wide). Row 1: 2 cells (150 wide).
        let cells = (0..<5).map { _ in MockCell() }
        let frames = GridLayout(cells: cells)
            .frames(in: CGSize(width: 300, height: 200)).map { $0.frame }
        #expect(frames[0] == CGRect(x: 0,   y: 0,   width: 100, height: 100))
        #expect(frames[2] == CGRect(x: 200, y: 0,   width: 100, height: 100))
        #expect(frames[3] == CGRect(x: 0,   y: 100, width: 150, height: 100))
        #expect(frames[4] == CGRect(x: 150, y: 100, width: 150, height: 100))
    }

    @Test func framesApplyGapBetweenCells() {
        // 2 cells, 1 row of 2, width 210 with gap 10 → each 100 wide, second at x=110.
        let cells = (0..<2).map { _ in MockCell() }
        let frames = GridLayout(cells: cells)
            .frames(in: CGSize(width: 210, height: 100), gap: 10).map { $0.frame }
        #expect(frames[0] == CGRect(x: 0,   y: 0, width: 100, height: 100))
        #expect(frames[1] == CGRect(x: 110, y: 0, width: 100, height: 100))
    }

    @Test func framesPreserveCellIdentityAndOrder() {
        let cells = (0..<4).map { _ in MockCell() }
        let frames = GridLayout(cells: cells).frames(in: CGSize(width: 200, height: 200))
        #expect(frames.map { $0.cell.id } == cells.map { $0.id })
    }
```

- [ ] **Step 2: Run to verify failure**

Run the test command. Expected: FAILS to compile (`frames` undefined).

- [ ] **Step 3: Implement frames**

Add to `GridLayout.swift`:
```swift
import CoreGraphics

extension GridLayout {
    /// The frame for each cell within `size`, separated by `gap`, in display order.
    ///
    /// Cells fill row-major. Rows split the height equally. Within a row, cells
    /// split that row's width equally; the last (possibly partial) row stretches
    /// its cells across the full width. Origin is top-left (y grows downward).
    /// Returns an empty array for an empty layout or a non-positive `size`.
    func frames(in size: CGSize, gap: CGFloat = 0) -> [(cell: ViewType, frame: CGRect)] {
        let n = cells.count
        guard n > 0, size.width > 0, size.height > 0 else { return [] }

        let (rows, columns) = Self.dimensions(forCount: n)
        let rowHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        var result: [(cell: ViewType, frame: CGRect)] = []
        result.reserveCapacity(n)
        for index in 0..<n {
            let row = index / columns
            let col = index % columns
            let isLastRow = row == rows - 1
            let cellsInRow = isLastRow ? (n - row * columns) : columns
            let colWidth = (size.width - gap * CGFloat(cellsInRow - 1)) / CGFloat(cellsInRow)
            let frame = CGRect(
                x: CGFloat(col) * (colWidth + gap),
                y: CGFloat(row) * (rowHeight + gap),
                width: colWidth,
                height: rowHeight)
            result.append((cells[index], frame))
        }
        return result
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run the test command. Expected: `** TEST SUCCEEDED **`, all frame tests pass.

- [ ] **Step 5: Run the full GridLayout suite once more and commit**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd /Users/evan/.leo/agents/leoterm/macos
xcodebuild test -scheme Ghostty -configuration Debug -packageAuthorizationProvider netrc -only-testing:GhosttyTests/GridLayoutTests 2>&1 | tail -15
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/GridLayout.swift macos/Tests/Grid/GridLayoutTests.swift
git commit -m "feat(grid): row-major frame computation with last-row stretch and gaps"
```

---

## Self-Review

**Spec coverage (2a scope):** Packing rule (square-ish, width-biased) → Task 3 (`dimensions`) with the exact approved table. Cell ordering/insertion/removal → Task 2. Geometry/tiling (equal rows, last-row stretch, gaps) → Task 4 (`frames`). Headless verifiability → all tasks are pure model/geometry under `GhosttyTests`. Out-of-scope items (rendering, hover-grow, fixed cells, config, split removal) are explicitly deferred to 2b–2e.

**Placeholder scan:** Every code and test block is complete and concrete. The only discovery step (Task 1 Step 3 confirming synchronized-group inclusion) is a real verification with a defined BLOCKED fallback, not a placeholder.

**Type consistency:** `GridLayout<ViewType: Identifiable>`, `cells`, `count`, `isEmpty`, `contains(id:)`, `appending(_:)`, `removing(id:)`, `dimensions(forCount:)`, `dimensions`, and `frames(in:gap:)` are defined once and referenced with identical signatures across tasks. `frames` returns `[(cell: ViewType, frame: CGRect)]` consistently in impl and tests. `MockCell` (Identifiable, Equatable) is the single test double throughout.

**Math check:** Packing `rows=floor(√n)`, `columns=ceil(n/rows)` verified against the table (n=3→1×3, n=5→2×3, n=9→3×3). Frame math verified for n=1 (full bounds), n=3 (equal thirds), n=5 (last row 2×150 stretch), and gap handling (width 210, gap 10 → 100-wide cells).

**Next:** Phase 2b — `TerminalGridView` renders this model into SwiftUI (`SurfaceWrapper` per cell using `frames(in:)` inside a `GeometryReader`), wired into `BaseTerminalController` as an alternative to `TerminalSplitTreeView`. (UI rendering can't be visually verified from this environment — rely on the model tests here plus Evan's manual check.)
