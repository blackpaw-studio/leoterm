# Leo Phase 5 — Status Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface per-cell "needs you" status (amber pulsing dot + glowing border) for agent cells, derived from a terminal bell, and roll the count up to a Dock/window-title badge so a waiting agent is noticed across Spaces.

**Architecture:** A terminal BEL emitted by an agent arrives in the tmux control-mode `%output` byte stream. The Zig viewer detects the `0x07` byte and emits a new `.bell` action, which the stream handler routes to the **existing** `.ring_bell` surface message — lighting up `SurfaceView.bell` (which already auto-clears on focus/keydown). On the Swift side, a pure `CellStatus` derivation maps `(isAgent, hasBell, lifecycle)` to a status; a small observable publishes per-cell status; `TerminalGridView` draws a status-dot + glow overlay; and a rollup counts `needsYou` cells into the Dock badge and window title.

**Tech Stack:** Zig 0.15.2 (tmux control-mode core), Swift/SwiftUI + AppKit (macOS app, target macOS 13), Combine. Build with **Xcode 26.3** (`DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`) — Xcode 26.5's SDK breaks the Zig link step.

---

## Scope & Key Findings (read before starting)

**Critical correction to the original design spec.** The spec (§5.4) lists "terminal bell (BEL) — reported by tmux over control mode (`%bell`)" as the needs-you signal. **There is no `%bell` control-mode notification.** Verified against `man tmux` CONTROL MODE — the complete notification set is: `%begin/%end/%error`, `%client-detached`, `%client-session-changed`, `%config-error`, `%continue`, `%exit`, `%extended-output`, `%layout-change`, `%message`, `%output`, `%pane-mode-changed`, `%paste-buffer-changed`, `%paste-buffer-deleted`, `%pause`, `%session-changed`, `%session-renamed`, `%session-window-changed`, `%sessions-changed`, `%subscription-changed`, `%unlinked-window-*`, `%window-add`, `%window-close`, `%window-pane-changed`, `%window-renamed`. No bell.

A bell instead arrives as a raw `0x07` byte inside the pane's `%output` data (tmux escapes it as `\007`; `control.zig`'s `unescapeOutput` already decodes it to a literal `0x07` before the viewer sees it — see `src/terminal/tmux/control.zig:273`). So Phase 5 detects the BEL byte in the decoded `%output` stream. This is a heuristic (a `0x07` embedded inside an OSC/DCS payload would also trip it), which is acceptable for a "needs you" hint and matches how a real terminal would ring anyway.

**v1 scope (this plan):**
- **needs-you** status from BEL → amber pulsing dot + glowing border on agent cells.
- **idle** status (grey dot) as the default for a live agent cell.
- needs-you **count rollup** → Dock badge + window-title suffix (Leo-specific, not gated on Ghostty's `bell-features`).
- needs-you **auto-clears** when you focus/type into the cell (reuses existing `SurfaceView.bell` clear-on-interaction).

**Explicitly deferred (NOT in this plan — call out to Evan):**
- **working** (green) activity dot. Requires new Zig→Swift per-output activity plumbing (a new apprt action round-trip) and idle-threshold/flicker tuning that can't be verified from an agent session. Low value relative to needs-you. Track as Phase 5b.
- **error/exited** (red) live-cell status. Phase 4 already reconciles stopped agents into `DeadCellView` placeholders, so the exited case is already represented. The `CellStatus.error` case is defined here for completeness but only derived from daemon lifecycle as a fallback.
- **Claude Code Notification hook → Leo relay** (spec §5.4 signal #1). Needs a daemon-side relay that does not exist yet.
- **Prompt-pattern heuristic** (spec §5.4 signal #3). The immediate follow-on after this plan if BEL coverage proves insufficient.

**Why bell reuse is the right spine:** the pty BEL path is already wired end-to-end (`stream.zig:812` → `stream_handler.bell()` → `apprt/surface.zig` `.ring_bell` → `Surface.zig:1106` → `SurfaceView.bell` published → `BaseTerminalController` aggregation → Dock badge). Routing the tmux-pane bell into the same `.ring_bell` message means `SurfaceView.bell` lights up for agent cells for free, including its clear-on-focus/keydown behavior — exactly the needs-you lifecycle we want.

---

## File Structure

**Zig (core) — modify:**
- `src/terminal/tmux/viewer.zig` — add `.bell` to the `Action` union; add a pure `outputHasBell` predicate; emit `.bell` from the `.output` arm of `nextCommand`.
- `src/termio/stream_handler.zig` — route the new `.bell` viewer action to the existing `.ring_bell` surface message in the `dcsCommand` action loop.

**Swift (app) — create:**
- `macos/Sources/Features/Leo/CellStatus.swift` — `CellStatus` enum + pure `deriveCellStatus(...)` function + display attributes (color, isPulsing).
- `macos/Sources/Features/Grid/CellStatusOverlay.swift` — SwiftUI overlay view (status dot + glow border) given a `CellStatus`.
- `macos/Tests/Leo/CellStatusTests.swift` — unit tests for the derivation.

**Swift (app) — modify:**
- `macos/Sources/Features/Grid/TerminalGridView.swift` — bind each cell's `SurfaceView` + `CellRegistry`/`LeoAgentStore` to a `CellStatus` and add the overlay to `cellView(for:isSplit:)`.
- `macos/Sources/App/macOS/AppDelegate.swift` — extend `setDockBadge()` to count needs-you agent cells.
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` — expose a `needsYouCount` and append a suffix in `computeTitle()`.

---

## Task 1: Zig — detect BEL in `%output` and route it to `.ring_bell`

**Files:**
- Modify: `src/terminal/tmux/viewer.zig` (`Action` union near `:196-216`; `nextCommand` `.output` arm near `:513-533`)
- Modify: `src/termio/stream_handler.zig` (`dcsCommand` action loop near `:504-535`)

This task must keep the codebase compiling at the predicate step, then add the enum variant and BOTH its producer (viewer) and consumer (stream_handler exhaustive switch) together — adding `.bell` to the union without a matching switch arm fails Zig's exhaustive-switch check.

- [ ] **Step 1: Write the failing test for the BEL predicate**

Add to the test block at the bottom of `src/terminal/tmux/viewer.zig`:

```zig
test "outputHasBell detects a BEL byte" {
    try std.testing.expect(Viewer.outputHasBell(&[_]u8{ 'h', 'i', 0x07 }));
    try std.testing.expect(Viewer.outputHasBell(&[_]u8{0x07}));
    try std.testing.expect(!Viewer.outputHasBell("hello world"));
    try std.testing.expect(!Viewer.outputHasBell(""));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  zig build test -Dtest-filter="outputHasBell detects a BEL byte"
```
Expected: compile error — `outputHasBell` is not declared on `Viewer`.

- [ ] **Step 3: Add the pure predicate**

Add inside the `Viewer` struct in `src/terminal/tmux/viewer.zig` (place it just above `receivedOutput` near `:1187` so it sits next to its only caller):

```zig
/// True if the decoded %output data contains a terminal BEL (0x07).
/// tmux has no %bell control-mode notification, so a bell is detected as a
/// raw byte in the pane output stream. This is a heuristic: a 0x07 embedded
/// in an OSC/DCS payload would also match, which is acceptable for a
/// best-effort "needs you" signal.
fn outputHasBell(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, 0x07) != null;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  zig build test -Dtest-filter="outputHasBell detects a BEL byte"
```
Expected: PASS.

- [ ] **Step 5: Add the `.bell` action variant**

In the `Action` union in `src/terminal/tmux/viewer.zig` (after the `redraw` variant near `:216`), add:

```zig
        /// The active pane (or any tracked pane) emitted a terminal bell
        /// (0x07 in its %output). The caller should surface this as user
        /// attention ("needs you"). Carries no payload.
        bell,
```

- [ ] **Step 6: Emit `.bell` from the `.output` arm of `nextCommand`**

In `src/terminal/tmux/viewer.zig`, the `.output` arm currently appends `.redraw` when `changed` (near `:513-533`). Append a `.bell` action when the output contains a BEL. Replace the inner `if (changed) { ... }` block with:

```zig
                if (changed) {
                    var arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = arena.state;
                    actions.append(arena.allocator(), .redraw) catch {
                        log.warn("failed to queue redraw action for pane output", .{});
                    };
                    if (outputHasBell(out.data)) {
                        actions.append(arena.allocator(), .bell) catch {
                            log.warn("failed to queue bell action for pane output", .{});
                        };
                    }
                }
```

- [ ] **Step 7: Handle the `.bell` action in stream_handler**

In `src/termio/stream_handler.zig`, the `dcsCommand` action loop switches over viewer actions (near `:506-534`). Add a `.bell` arm alongside the existing arms (after the `.windows, .redraw` arm near `:533`):

```zig
                        // A tracked pane rang the bell; route it through the
                        // existing surface bell path so SurfaceView.bell lights
                        // up (and auto-clears on focus/keydown) for the agent
                        // cell — the macOS "needs you" signal.
                        .bell => self.surfaceMessageWriter(.ring_bell),
```

- [ ] **Step 8: Build to verify the exhaustive switch compiles and the predicate test still passes**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  zig build test -Demit-macos-app=false -Dtest-filter="outputHasBell detects a BEL byte"
```
Expected: builds clean (no "unhandled enumeration value" error) and the test passes.

- [ ] **Step 9: Commit**

```bash
git add src/terminal/tmux/viewer.zig src/termio/stream_handler.zig
git commit -m "feat(leo): detect tmux pane BEL in %output and route to ring_bell"
```

---

## Task 2: Swift — `CellStatus` model + pure derivation

**Files:**
- Create: `macos/Sources/Features/Leo/CellStatus.swift`
- Test: `macos/Tests/Leo/CellStatusTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/Leo/CellStatusTests.swift`:

```swift
import XCTest
@testable import Ghostty

final class CellStatusTests: XCTestCase {
    func testAgentWithBellNeedsYou() {
        let status = deriveCellStatus(isAgent: true, hasBell: true, lifecycle: .running)
        XCTAssertEqual(status, .needsYou)
    }

    func testAgentRunningNoBellIsIdle() {
        let status = deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .running)
        XCTAssertEqual(status, .idle)
    }

    func testStoppedAgentIsError() {
        let status = deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .stopped)
        XCTAssertEqual(status, .error)
    }

    func testBellOnStoppedAgentStillError() {
        // Lifecycle error outranks a stale bell.
        let status = deriveCellStatus(isAgent: true, hasBell: true, lifecycle: .stopped)
        XCTAssertEqual(status, .error)
    }

    func testPtyCellNeverNeedsYou() {
        // Plain terminal cells use activity-only semantics (spec 5.1/5.3);
        // a bell does not promote a pty cell to needsYou.
        let status = deriveCellStatus(isAgent: false, hasBell: true, lifecycle: nil)
        XCTAssertEqual(status, .idle)
    }

    func testNeedsYouIsPulsingAmber() {
        XCTAssertTrue(CellStatus.needsYou.isPulsing)
    }

    func testIdleIsNotPulsing() {
        XCTAssertFalse(CellStatus.idle.isPulsing)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS' -packageAuthorizationProvider netrc \
  -only-testing:GhosttyTests/CellStatusTests 2>&1 | tail -20
```
Expected: FAIL — `deriveCellStatus` / `CellStatus` undefined.

- [ ] **Step 3: Implement `CellStatus` + derivation**

Create `macos/Sources/Features/Leo/CellStatus.swift`:

```swift
import SwiftUI

/// Activity/attention status of a grid cell, derived from cell signals.
/// Distinct from `AgentStatus` (daemon lifecycle running/stopped) — this is the
/// Phase 5 status-language concept (spec §5.3) shown as a dot + border.
enum CellStatus: Equatable {
    /// Output actively flowing. NOTE: not derived in v1 (deferred); reserved.
    case working
    /// Quiet, nothing happening. Default for a live cell.
    case idle
    /// Agent is waiting on the user (a bell rang). Amber, pulsing.
    case needsYou
    /// Process error or exit (daemon lifecycle stopped). Red.
    case error

    /// Dot color for this status.
    var color: Color {
        switch self {
        case .working: return .green
        case .idle: return .secondary
        case .needsYou: return .orange
        case .error: return .red
        }
    }

    /// Whether the dot/border should pulse to draw attention.
    var isPulsing: Bool { self == .needsYou }

    /// Whether this status warrants a glowing cell border.
    var hasGlow: Bool { self == .needsYou }
}

/// Pure derivation of a cell's status from its signals. Priority:
/// error (lifecycle stopped) > needsYou (bell, agents only) > idle.
/// `working` is deferred in v1 and never produced here.
/// - Parameters:
///   - isAgent: true for `.agent` cells; false for plain `.pty` cells.
///   - hasBell: the backing surface's current bell flag.
///   - lifecycle: the daemon-reported lifecycle, or nil for pty cells.
func deriveCellStatus(
    isAgent: Bool,
    hasBell: Bool,
    lifecycle: AgentStatus?
) -> CellStatus {
    if isAgent, lifecycle == .stopped { return .error }
    if isAgent, hasBell { return .needsYou }
    return .idle
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS' -packageAuthorizationProvider netrc \
  -only-testing:GhosttyTests/CellStatusTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Lint and commit**

```bash
(cd macos && swiftlint lint --strict --quiet)   # expect no output (exit 0)
git add macos/Sources/Features/Leo/CellStatus.swift macos/Tests/Leo/CellStatusTests.swift
git commit -m "feat(leo): CellStatus model + pure status derivation"
```

---

## Task 3: Swift — status-dot + glow overlay view

**Files:**
- Create: `macos/Sources/Features/Grid/CellStatusOverlay.swift`

This is a pure view with no logic to unit-test; correctness is verified in the GUI (Task 6). Keep it self-contained so it can be previewed in isolation.

- [ ] **Step 1: Implement the overlay view**

Create `macos/Sources/Features/Grid/CellStatusOverlay.swift`:

```swift
import SwiftUI

/// A small status indicator drawn over a grid cell: a corner dot, plus an
/// optional glowing border for attention states. Pure presentation — driven
/// entirely by the `status` it is handed.
struct CellStatusOverlay: View {
    let status: CellStatus

    @State private var pulse = false

    private let dotSize: CGFloat = 9
    private let dotInset: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Glow border for attention states.
            if status.hasGlow {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(status.color, lineWidth: 2)
                    .shadow(color: status.color.opacity(0.8), radius: pulse ? 6 : 2)
                    .opacity(pulse ? 1.0 : 0.55)
                    .allowsHitTesting(false)
            }

            // Corner status dot.
            Circle()
                .fill(status.color)
                .frame(width: dotSize, height: dotSize)
                .opacity(status.isPulsing ? (pulse ? 1.0 : 0.4) : 0.9)
                .padding(dotInset)
                .allowsHitTesting(false)
        }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: status) { _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        guard status.isPulsing else {
            pulse = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS' -packageAuthorizationProvider netrc 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

> NOTE on `onChange(of:)`: the app targets macOS 13, which uses the two-parameter `onChange(of:perform:)` form shown above (`{ _ in ... }`). Do NOT use the macOS-14 zero/two-value closure form.

- [ ] **Step 3: Lint and commit**

```bash
(cd macos && swiftlint lint --strict --quiet)
git add macos/Sources/Features/Grid/CellStatusOverlay.swift
git commit -m "feat(leo): CellStatusOverlay view (status dot + glow border)"
```

---

## Task 4: Swift — bind per-cell status in `TerminalGridView`

**Files:**
- Modify: `macos/Sources/Features/Grid/TerminalGridView.swift` (`cellView(for:isSplit:)` near `:78-90`)

The grid already renders each cell and has access to the cell's `Ghostty.SurfaceView` (which publishes `bell`) and, via the Phase 4 `CellRegistry`, the `CellSource` (`.agent(name:)` vs `.pty`). The `LeoAgentStore` (or `LeoSidebarModel`) holds the daemon roster for lifecycle. This task computes a `CellStatus` per cell and overlays it.

- [ ] **Step 1: Add a status helper to the grid view**

In `TerminalGridView.swift`, add a method that resolves a cell's status from its surface + registry + agent store. Use the exact accessors the surrounding code already uses to reach the registry and agent store (the grid already receives a `cellRegistry`/board context in Phase 4 — reuse that property; do not introduce a new dependency path). Add:

```swift
    /// Resolve the Phase 5 status for a given cell's surface.
    private func status(for surface: Ghostty.SurfaceView) -> CellStatus {
        let source = cellRegistry.source(for: surface.id)
        let isAgent = source?.isAgent ?? false
        var lifecycle: AgentStatus?
        if case .agent(let name) = source {
            lifecycle = agentStore.agents.first(where: { $0.name == name })?.status
        }
        return deriveCellStatus(
            isAgent: isAgent,
            hasBell: surface.bell,
            lifecycle: lifecycle
        )
    }
```

> If `cellRegistry` / `agentStore` are not already in scope in `TerminalGridView`, thread them in from the parent the same way the Phase 4 board actions are passed (see how `TerminalView` constructs the grid). Match the existing injection pattern — do not reach for a singleton.

- [ ] **Step 2: Add the overlay to the cell view**

In `cellView(for:isSplit:)` (near `:78-90`), add a `.overlay` on the cell content, as a sibling to the existing pin-handle overlay (near `:94-110`). Because the status depends on `surface.bell` (a `@Published` property), the cell view must observe the surface; the grid already renders `Ghostty.SurfaceView`s as `@ObservedObject`-backed content, so reading `surface.bell` here re-renders on change. Add:

```swift
            .overlay {
                CellStatusOverlay(status: status(for: surface))
            }
```

Place this BEFORE the pin-handle `.overlay(alignment: .bottom)` so the pin handle stays on top and remains draggable.

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS' -packageAuthorizationProvider netrc 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Lint and commit**

```bash
(cd macos && swiftlint lint --strict --quiet)
git add macos/Sources/Features/Grid/TerminalGridView.swift
git commit -m "feat(leo): overlay per-cell status dot/border in the grid"
```

---

## Task 5: Swift — needs-you rollup to Dock badge + window title

**Files:**
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift` (`computeTitle` near `:992-999`; add a `needsYouCount`)
- Modify: `macos/Sources/App/macOS/AppDelegate.swift` (`setDockBadge()` near `:746-754`)

The existing `setDockBadge()` counts windows whose `bell == true` and is gated on `ghostty.config.bellFeatures.contains(.attention)`. For Leo we want a per-cell needs-you count that is NOT gated on Ghostty's bell-features (it's a Leo feature). Since agent bells route through `.ring_bell`, the controller's aggregated `bell` flag already reflects "some cell in this window needs you" — reuse it, but ungate and label as needs-you.

- [ ] **Step 1: Expose a needs-you count on the controller**

In `BaseTerminalController.swift`, add a computed property that counts agent surfaces currently ringing. Reuse the existing `surfaceValuesPublisher`/tree-walk the controller already uses for bell aggregation (near `:1719-1737`); the simplest correct count is the number of surfaces in this controller's tree whose `bell == true` AND whose `CellSource` is an agent. Add:

```swift
    /// Number of agent cells in this window currently signaling "needs you".
    /// Plain pty cells are excluded (spec §5.3: pty cells have no needs-you).
    var needsYouCount: Int {
        leoCellRegistry?.agentSurfaceIDsRinging(in: self).count ?? 0
    }
```

> `leoCellRegistry` is the Phase 4 registry already held by the controller (it owns `addCell`/`closeCell`). If a convenience like `agentSurfaceIDsRinging(in:)` does not exist, add a small helper on `CellRegistry` that, given the controller's surfaces, returns the IDs whose source is `.agent` and whose `SurfaceView.bell == true`. Keep the bell read on the main actor.

- [ ] **Step 2: Append needs-you to the window title**

In `computeTitle(title:bell:)` (near `:992-999`), after the existing bell-emoji prefix logic, append a needs-you suffix when there are waiting agents:

```swift
        var result = base   // whatever the existing function returns as the title
        let waiting = needsYouCount
        if waiting > 0 {
            result += " · \(waiting) needs you"
        }
        return result
```

> Adapt `base`/`result` to the existing local variable names in `computeTitle`. Do not remove the existing `🔔` bell-prefix behavior — add the suffix alongside it.

- [ ] **Step 3: Count needs-you cells in the Dock badge**

In `AppDelegate.setDockBadge()` (near `:746-754`), replace the per-window bell count with a sum of `needsYouCount` across controllers, ungated by `bellFeatures`:

```swift
        let needsYou = NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .reduce(0) { $0 + $1.needsYouCount }
        let label = needsYou > 0 ? (needsYou > 99 ? "99+" : String(needsYou)) : nil
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
```

> This supersedes the prior `bellFeatures.contains(.attention)` gating for the badge. Keep the existing notification-authorization checks in `syncDockBadge()` intact. `setDockBadge()` is already invoked from `terminalWindowHasBell(_:)` via `terminalWindowBellDidChangeNotification`, which fires when any surface's bell flips — so agent bells (routed through `.ring_bell`) already trigger a recount. No new notification wiring needed.

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS' -packageAuthorizationProvider netrc 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full Leo + grid suites to confirm no regressions**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS' -packageAuthorizationProvider netrc \
  -only-testing:GhosttyTests/Leo -only-testing:GhosttyTests/CellStatusTests 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Lint and commit**

```bash
(cd macos && swiftlint lint --strict --quiet)
git add macos/Sources/Features/Terminal/BaseTerminalController.swift \
        macos/Sources/App/macOS/AppDelegate.swift \
        macos/Sources/Features/Leo/CellRegistry.swift
git commit -m "feat(leo): roll up needs-you count to Dock badge + window title"
```

---

## Task 6: Manual GUI verification (Evan-driven)

The status chrome and badge are visual; they cannot be verified from an agent session (see the `gui-verification-constraint` memory). Build on Dionysus and launch on Evan's MacBook via the `xcode-remote` tool, then have Evan drive these checks.

- [ ] **Step 1: Build + launch on hardware**

Use the `xcode-remote` skill (config already at `.xcode-remote.toml`, `path = "macos"`). Confirm the app launches without a startup crash.

- [ ] **Step 2: Verification checklist (Evan)**

- [ ] Spawn/attach an agent cell; confirm a **grey idle dot** appears in its corner.
- [ ] Trigger a bell in the agent (e.g. an agent that finishes and rings, or `printf '\a'` in the agent's shell): the cell shows an **amber pulsing dot + glowing border**, the **window title** gains a "· N needs you" suffix, and the **Dock badge** shows the count.
- [ ] Focus/click or type into the cell: needs-you **clears** (dot returns to grey, badge/ title decrement).
- [ ] With multiple agents, ring two: the **Dock badge reads 2**; clear one → reads 1.
- [ ] A **plain pty cell** that receives a bell does **not** show needs-you (stays idle) and is **not** counted in the badge.
- [ ] Stop an agent: its cell becomes a `DeadCellView` placeholder (Phase 4 behavior unchanged) — no red live-cell dot needed.

- [ ] **Step 3: Record results in project-status memory and decide on Phase 5b**

If BEL coverage feels insufficient (agents that don't ring), that's the trigger to implement the deferred **prompt-pattern heuristic** and/or the **Claude Code Notification hook relay** as Phase 5b. Note the outcome in `leo-project-status.md`.

---

## Self-Review

**Spec coverage (design §5.3 status language, §5.4 needs-you, §5.4 badge rollup):**
- Needs-you (amber, pulsing dot + glowing border): Tasks 1–4. ✓
- Idle (grey): default in `deriveCellStatus`, Task 2. ✓
- Working (green): **deferred** — documented in Scope. ⚠ (intentional)
- Error/exited (red): `.error` case defined; live-cell red deferred because Phase 4 dead-cells already cover the exited case. Documented. ⚠ (intentional)
- Needs-you count → window-title / Dock badge: Task 5. ✓
- Layered signals: signal #2 (bell) implemented; #1 (hook relay) and #3 (prompt heuristic) deferred to Phase 5b, matching the spec's own risk-table v1 guidance. ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to" steps. The UI-wiring steps (Tasks 4–5) contain real code plus exact file:line anchors; where a Phase-4 accessor name (`cellRegistry`, `agentStore`, `leoCellRegistry`, `computeTitle` locals) may differ from the actual symbol, the step names the exact file and the pattern to match rather than inventing a signature — these are integration points against existing Phase 4 code the implementer can see, not undefined types.

**Type consistency:** `CellStatus` (cases `working`/`idle`/`needsYou`/`error`; props `color`/`isPulsing`/`hasGlow`) and `deriveCellStatus(isAgent:hasBell:lifecycle:)` are defined in Task 2 and used identically in Tasks 3–4. `AgentStatus` (`.running`/`.stopped`) is the existing Phase 4 enum (`LeoModels.swift`). The Zig `.bell` action is produced in viewer.zig (Task 1 Steps 5–6) and consumed in stream_handler.zig (Task 1 Step 7) — both in the same task to keep the exhaustive switch valid. `.ring_bell` is the existing `apprt/surface.zig` message.

**Build-order safety:** Task 1 keeps Zig compiling at each commit (predicate first; enum variant + producer + consumer together). Swift tasks each end with a green build/test + lint + commit.
