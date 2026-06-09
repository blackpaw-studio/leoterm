# Leo — Phase 2b: TerminalGridView Rendering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the window's terminal surfaces as an auto-arranging grid by adding a `TerminalGridView` (driven by the Phase 2a `GridLayout`) and swapping it in for `TerminalSplitTreeView` at the single call site in `TerminalView`. Result: opening additional surfaces (via the existing split actions) auto-packs them into a grid, with click-to-focus and zoom passthrough.

**Architecture:** `TerminalGridView` mirrors `TerminalSplitTreeView`'s interface (`tree`, `action`) so it drops in at the same call site. It reads the tree's leaves in display order (`Array(tree)` via the existing `SplitTree: Sequence` conformance), feeds them to `GridLayout`, and positions each cell with `GridLayout.frames(in:gap:)` inside a `GeometryReader`. Each cell reuses Ghostty's existing `Ghostty.InspectableSurface` wrapper; clicking a cell calls `Ghostty.moveFocus(to:)` (sticky focus — focus changes only on click). When `tree.zoomed` is set, the single zoomed leaf fills the window. `TerminalSplitTreeView` is left in the tree (unused) and removed later in Phase 2e.

**Tech Stack:** Swift 6, SwiftUI, Xcode 26.3 (`DEVELOPER_DIR`), `Ghostty` app target (filesystem-synchronized groups). Verification = the app target **builds**; visual/interaction behavior is verified by Evan on a real display (this environment can't render the GUI — see `LEO.md` / memory).

---

## Scope

**Phase 2b only** (spec §2–3): dynamic auto-packed rendering, click-to-focus, zoom passthrough. **Out of scope (later sub-plans):** hover-grow (2c), fixed/pinned cells + drag-resize (2d), the "new plain-terminal cell" action + `leo` config + removal of the split UI (2e). The gap between cells is a hardcoded constant here; it becomes configurable in 2e.

## Verified integration points (from source, exact)

- **Call site** — `macos/Sources/Features/Terminal/TerminalView.swift:82-88`:
  ```swift
  TerminalSplitTreeView(
      tree: viewModel.surfaceTree,
      action: { delegate?.performSplitAction($0) })
      .environmentObject(ghostty)
      .ghosttyLastFocusedSurface(lastFocusedSurface)
      .focused($focused)
  ```
- **Interface to mirror** — `macos/Sources/Features/Splits/TerminalSplitTreeView.swift:28-45`:
  ```swift
  struct TerminalSplitTreeView: View {
      let tree: SplitTree<Ghostty.SurfaceView>
      let action: (TerminalSplitOperation) -> Void
      ...
  }
  ```
- **Ordered leaves** — `SplitTree: Sequence` (SplitTree.swift:1181) → `Array(tree)` yields `[Ghostty.SurfaceView]` left→right, top→bottom. Also `tree.root?.leaves()`.
- **Cell wrapper** — leaves render via `Ghostty.InspectableSurface(surfaceView:isSplit:)` (TerminalSplitTreeView.swift:99).
- **Focus** — `Ghostty.moveFocus(to:from:delay:)` (SurfaceView.swift:1141); call `Ghostty.moveFocus(to: surface)`.
- **Zoom** — render branches on `tree.zoomed ?? tree.root`; `tree.zoomed` is a `SplitTree<…>.Node?`.

## File / change map

- Create: `macos/Sources/Features/Grid/TerminalGridView.swift` (auto-included in `Ghostty` target).
- Modify: `macos/Sources/Features/Terminal/TerminalView.swift` — swap one type name at the call site (line ~82).
- `TerminalSplitTreeView.swift` is **not** modified or deleted in 2b.

## Build command (this environment)

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd /Users/evan/.leo/agents/leoterm/macos
xcodebuild -target Ghostty -configuration Debug -packageAuthorizationProvider netrc build 2>&1 | tail -25
```
Set the Bash tool `timeout` to 600000 (first build is slow). Success = `** BUILD SUCCEEDED **`.

---

### Task 1: Create `TerminalGridView`

**Files:**
- Create: `macos/Sources/Features/Grid/TerminalGridView.swift`

- [ ] **Step 1: Write the view**

Create `macos/Sources/Features/Grid/TerminalGridView.swift`:
```swift
import SwiftUI

/// Renders the window's terminal surfaces as an auto-arranging grid — Leo's
/// replacement for the binary `TerminalSplitTreeView`. It mirrors that view's
/// interface (`tree`, `action`) so it drops in at the same call site.
///
/// Phase 2b: dynamic auto-packing (via `GridLayout`), click-to-focus (sticky),
/// and zoom passthrough. Hover-grow, fixed/pinned cells, and drag-resize are
/// added in later phases.
struct TerminalGridView: View {
    /// The window's surface tree. We render its leaves (in display order) as a grid.
    let tree: SplitTree<Ghostty.SurfaceView>

    /// Split operations raised to the controller (kept for interface parity and
    /// future drag/resize support; unused by the grid in this phase).
    let action: (TerminalSplitOperation) -> Void

    /// Gap between cells, in points. Made configurable in Phase 2e.
    private let gap: CGFloat = 4

    var body: some View {
        // Zoom takes precedence: a single zoomed leaf fills the window.
        if let zoomed = tree.zoomed, case .leaf(let surface) = zoomed {
            Ghostty.InspectableSurface(surfaceView: surface, isSplit: false)
        } else {
            grid
        }
    }

    private var grid: some View {
        // Ordered leaves: left→right, top→bottom (SplitTree: Sequence).
        let surfaces = Array(tree)
        let isSplit = surfaces.count > 1
        return GeometryReader { geo in
            let placed = GridLayout(cells: surfaces).frames(in: geo.size, gap: gap)
            ZStack(alignment: .topLeading) {
                ForEach(placed, id: \.cell.id) { item in
                    Ghostty.InspectableSurface(surfaceView: item.cell, isSplit: isSplit)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                        .onTapGesture { Ghostty.moveFocus(to: item.cell) }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build the app target (compiles the new, as-yet-unused file)**

Run the build command from the header. Expected: `** BUILD SUCCEEDED **`.

Likely-symbol fixes if the build errors (apply the minimal fix, do not redesign):
- If `Ghostty.moveFocus(to:)` is not found: `grep -rn "func moveFocus" macos/Sources` and use the exact qualified name it reveals (it may be `Ghostty.SurfaceView.moveFocus(to:)`).
- If `Ghostty.InspectableSurface` is not found at that path: `grep -rn "struct InspectableSurface" macos/Sources` and use the exact name/qualification (it may be `Ghostty.InspectableSurface` or `InspectableSurface`).
- If `case .leaf(let surface)` errors on the associated-value label: use `case .leaf(let surface)` positionally; if the compiler insists, write `if case let .leaf(surface) = zoomed`.
- If `ForEach(placed, id: \.cell.id)` errors: the element is a tuple `(cell: Ghostty.SurfaceView, frame: CGRect)`; `\.cell.id` is the `UUID` id. If tuple key paths are rejected, map to a small `Identifiable` wrapper struct `PlacedCell { let id: UUID; let surface: Ghostty.SurfaceView; let frame: CGRect }` built from `placed`, and `ForEach` over that.

- [ ] **Step 3: Commit**

```bash
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Grid/TerminalGridView.swift
git commit -m "feat(grid): add TerminalGridView rendering GridLayout of surfaces"
```

---

### Task 2: Swap `TerminalGridView` in at the `TerminalView` call site

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalView.swift` (line ~82)

- [ ] **Step 1: Confirm the exact current call site**

Run:
```bash
grep -n "TerminalSplitTreeView(" macos/Sources/Features/Terminal/TerminalView.swift
```
Expected: one match around line 82.

- [ ] **Step 2: Replace the type name only**

In `macos/Sources/Features/Terminal/TerminalView.swift`, change the single call-site occurrence:
```swift
        TerminalSplitTreeView(
            tree: viewModel.surfaceTree,
            action: { delegate?.performSplitAction($0) })
            .environmentObject(ghostty)
            .ghosttyLastFocusedSurface(lastFocusedSurface)
            .focused($focused)
```
to:
```swift
        TerminalGridView(
            tree: viewModel.surfaceTree,
            action: { delegate?.performSplitAction($0) })
            .environmentObject(ghostty)
            .ghosttyLastFocusedSurface(lastFocusedSurface)
            .focused($focused)
```
Change ONLY the type name `TerminalSplitTreeView` → `TerminalGridView`. Leave the arguments and the three view modifiers exactly as-is. Do not touch any other `TerminalSplitTreeView` references elsewhere in the codebase.

- [ ] **Step 3: Build the app**

Run the build command from the header. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/evan/.leo/agents/leoterm
git add macos/Sources/Features/Terminal/TerminalView.swift
git commit -m "feat(grid): render terminal window with TerminalGridView (grid replaces split layout)"
```

- [ ] **Step 5: Note for visual verification (no action — controller/Evan)**

The build succeeding is the automated gate. Visual/interaction verification (open the app, create surfaces via the existing split key bindings, confirm they auto-pack into a grid and clicking focuses a cell) must be done by Evan on a real display:
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
open macos/build/Debug/Ghostty.app
```

---

## Self-Review

**Spec coverage (2b scope):** Grid rendering of surfaces → `TerminalGridView.grid` using the tested `GridLayout.frames`. Auto-packing → inherited from `GridLayout` (Phase 2a). Sticky click-to-focus → `.onTapGesture { Ghostty.moveFocus(to:) }` (focus changes only on click). Zoom → `tree.zoomed` branch. Drop-in replacement → mirrors `TerminalSplitTreeView(tree:action:)` and swaps at the one call site. Deferred (hover-grow, fixed cells, config, split removal) explicitly out of scope.

**Placeholder scan:** The view code is complete. The "likely-symbol fixes" in Task 1 Step 2 are concrete, command-driven contingencies for exact-name uncertainty (with the precise grep to resolve each), not vague placeholders — necessary because the final qualified names of `moveFocus`/`InspectableSurface` are best confirmed against the compiler.

**Type consistency:** `TerminalGridView(tree: SplitTree<Ghostty.SurfaceView>, action: (TerminalSplitOperation) -> Void)` matches `TerminalSplitTreeView`'s interface exactly, so the call-site swap in Task 2 is type-compatible. `GridLayout(cells:)` and `.frames(in:gap:)` match the Phase 2a API. `Array(tree)` relies on the verified `SplitTree: Sequence` conformance yielding `[Ghostty.SurfaceView]`.

**Verification honesty:** Build-success is the only automated signal available here; the plan explicitly hands visual/interaction verification to Evan rather than claiming it.

**Next:** Phase 2c — hover-grow (mode A, elastic reflow) layered onto `TerminalGridView`, with debounced PTY resize and the sticky-focus-stays-grown behavior.
