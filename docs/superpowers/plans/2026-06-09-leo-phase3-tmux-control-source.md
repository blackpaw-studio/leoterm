# Leo Phase 3 — tmux Control-Mode Cell Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a Leo agent's tmux session natively inside a Ghostty grid cell by driving tmux control mode (`-CC`) through Ghostty's already-shipped tmux `Viewer`, plus a Swift `CellSource` abstraction that distinguishes plain ($SHELL) cells from agent cells.

**Architecture:** Upstream Ghostty already contains a complete, tested tmux control-mode parser + `Viewer` state machine (`src/terminal/tmux/`, 114 tests) wired into `stream_handler.zig` — but the pane-rendering step is a literal `// TODO` and there is **no input/resize back-path**. We finish that frontier for the single-pane case that matches Leo's actual topology (one tmux server `-L leo`, one session `leo-<name>` per agent, one window, one pane). A cell that runs `leo agent attach --cc <name>` emits the control-mode DCS into its surface PTY; the `Viewer` parses it and populates a per-pane `Terminal`; we **mirror** that pane's active screen into the host surface's `Terminal` so the existing Metal renderer draws it unchanged; and we extend the `Viewer` with an `Input` variant so host keystrokes/resizes become tmux `send-keys` / `refresh-client` commands. On the Swift side, a `CellSource` enum (`PTYSource` vs `AgentSource`) produces the per-surface `SurfaceConfiguration.command`.

**Tech Stack:** Zig 0.15.2 (terminal core, `src/terminal/tmux/`, `src/termio/stream_handler.zig`), Swift + Swift Testing (`macos/`), tmux control mode (`tmux -L leo -CC`), libghostty embedding API.

**Build/verify reminders (from project memory):**
- Always export `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer` for every `zig`/`xcodebuild` command (Xcode 26.5 breaks the Zig link step — see `leo-build-toolchain` memory).
- Zig core test: `zig build test-lib-vt -Dtest-filter=<name>` for `src/terminal/...` changes (preferred), or `zig build test -Dtest-filter=<name>`.
- Swift: run `cd macos && swiftlint lint --strict --quiet` and fix ALL output before every commit.
- **GUI cannot be verified from this agent session** (`gui-verification-constraint` memory). Every task below is structured so correctness is proven by a headless unit test (screen-string assertions, command-string assertions, config assertions). The actual on-screen pixels are hand-verified by Evan at the end.

**Topology facts this plan depends on (verified against the live daemon 2026-06-09):**
- One tmux server, socket name `leo` → all tmux invocations use `-L leo`.
- Each agent = one session named `leo-<name>` (e.g. agent `leoterm` → session `leo-leoterm`). `leo agent session-name <shorthand>` resolves it.
- Each session is currently **1 window, 1 pane**. This plan renders the **single active pane**; multi-pane windows render the active pane only (a documented, logged limitation — Phase 6 can tile panes as sub-cells if ever needed).
- `leo agent attach --cc <name>` execs `tmux -L leo -CC attach -t leo-<name>`, whose stdout carries the control-mode protocol (DCS `␛P1000p` … `%output` … `%exit` `␛\`).

---

## File Structure

**New files:**
- `macos/Sources/Features/Grid/CellSource.swift` — the `CellSource` enum + `surfaceConfiguration` mapping (Swift).
- `macos/Tests/Cell/CellSourceTests.swift` — Swift Testing unit tests for `CellSource`.
- `src/terminal/tmux/mirror.zig` — pure helper that mirrors the active pane's screen from a `Viewer` into a destination `Terminal`; plus its unit tests.
- `src/terminal/tmux/testdata/leo-agent-attach-CC.bin` — real captured control-mode transcript (already saved in this branch) used as a parser fixture.

**Modified files:**
- `src/terminal/tmux.zig` — export the new `mirror` helper.
- `src/terminal/tmux/control.zig` — add a parser test driving the real transcript fixture.
- `src/terminal/tmux/viewer.zig` — add `Input.keys` / `Input.resize` variants and emit `.command` actions for them; add a `pub fn activePaneTerminal()` accessor; tests.
- `src/termio/stream_handler.zig` — implement the `.windows` action (mirror active pane → host terminal, mark dirty, wake renderer) and route the viewer's `.exit`; add the call site that forwards keystrokes/resize into the viewer.
- `macos/Sources/Features/Grid/TerminalGridView.swift` (and/or the cell-creation call site) — thread a `CellSource` into surface creation.

---

## Task 1: `CellSource` Swift abstraction (PTYSource vs AgentSource)

Establishes the byte-source distinction at the Swift layer with zero core changes. After this task, code can construct a `SurfaceConfiguration` for either a plain shell cell or an agent cell. Rendering of agent cells is not yet wired (that's Tasks 3–4); an agent cell built now would launch `tmux -CC` and the viewer would parse but not draw — acceptable intermediate state, build-verified only.

**Files:**
- Create: `macos/Sources/Features/Grid/CellSource.swift`
- Create: `macos/Tests/Cell/CellSourceTests.swift`

**Background (verified):** `Ghostty.SurfaceConfiguration` (in `macos/Sources/Ghostty/Surface View/SurfaceView.swift:629+`) already has a `command: String?` field that maps to `ghostty_surface_config_s.command` (`include/ghostty.h:474`). When `command` is `nil`, libghostty spawns the configured `$SHELL`. `SurfaceView.init(_:baseConfig:uuid:)` accepts that config per surface. So `CellSource` only needs to produce the right `SurfaceConfiguration`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/Cell/CellSourceTests.swift`:

```swift
import Testing
@testable import Ghostty

struct CellSourceTests {
    @Test func ptySourceLeavesCommandNilToInheritShell() {
        let config = CellSource.pty.surfaceConfiguration
        #expect(config.command == nil)
    }

    @Test func agentSourceRunsLeoControlModeAttach() {
        let config = CellSource.agent(name: "leoterm").surfaceConfiguration
        #expect(config.command == "leo agent attach --cc leoterm")
    }

    @Test func agentSourcePreservesExactAgentName() {
        // Canonical daemon names can be long; they must pass through verbatim.
        let name = "leo-coding-blackpaw-studio-beacon"
        let config = CellSource.agent(name: name).surfaceConfiguration
        #expect(config.command == "leo agent attach --cc \(name)")
    }

    @Test func isAgentDistinguishesCellKinds() {
        #expect(CellSource.pty.isAgent == false)
        #expect(CellSource.agent(name: "x").isAgent == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd macos && xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty \
  -packageAuthorizationProvider netrc \
  -only-testing:GhosttyTests/CellSourceTests 2>&1 | tail -20
```
Expected: FAIL to compile — `CellSource` is not defined.

- [ ] **Step 3: Write minimal implementation**

Create `macos/Sources/Features/Grid/CellSource.swift`:

```swift
import Foundation

/// The byte source that backs a grid cell's terminal surface.
///
/// - `pty`: a plain terminal cell running the user's `$SHELL` (Ghostty's
///   default PTY path; `command == nil` inherits the configured shell).
/// - `agent`: a Leo agent cell. The surface runs `leo agent attach --cc
///   <name>`, which execs `tmux -L leo -CC attach -t leo-<name>`. The
///   control-mode protocol it emits is consumed by the terminal core's
///   tmux `Viewer` (see `src/terminal/tmux/`), not displayed verbatim.
///
/// Both cases resolve to a `Ghostty.SurfaceConfiguration`, so the renderer
/// and input stack stay agnostic to what backs a cell.
enum CellSource: Equatable {
    case pty
    case agent(name: String)

    /// True for cells backed by a Leo agent (carries agent status semantics).
    var isAgent: Bool {
        switch self {
        case .pty: return false
        case .agent: return true
        }
    }

    /// The per-surface configuration that launches this source.
    var surfaceConfiguration: Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        switch self {
        case .pty:
            config.command = nil // inherit $SHELL from global config
        case .agent(let name):
            config.command = "leo agent attach --cc \(name)"
        }
        return config
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd macos && xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty \
  -packageAuthorizationProvider netrc \
  -only-testing:GhosttyTests/CellSourceTests 2>&1 | tail -20
```
Expected: PASS (4 tests).

- [ ] **Step 5: Lint**

Run:
```bash
cd macos && swiftlint lint --strict --quiet
```
Expected: no output (clean). Fix any violations (watch the `comma` rule on aligned literals).

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Grid/CellSource.swift macos/Tests/Cell/CellSourceTests.swift
git commit -m "feat(cell): CellSource abstraction (PTYSource vs AgentSource)"
```

---

## Task 2: Real-transcript parser fixture test

Hardens the foundation and proves the captured real-world control-mode stream parses into the expected notifications. The fixture (`leo-agent-attach-CC.bin`, already saved in this branch) is the raw `tmux -L leo -CC attach -t leo-leoterm` output: DCS `␛P1000p`, `%begin/%end`, `%session-changed $25 leo-leoterm`, many `%output %25 …`, then `%exit` + ST.

**Files:**
- Modify: `src/terminal/tmux/control.zig` (add a test at the end, near the existing 18 tests)
- Uses: `src/terminal/tmux/testdata/leo-agent-attach-CC.bin` (already present)

**Background (verified):** `control.Parser` consumes the **inner** control-mode line stream (lines beginning with `%`), not the DCS wrapper — the DCS `␛P1000p … ␛\` envelope is stripped by `src/terminal/dcs.zig` before bytes reach the parser. So the test must feed the parser the bytes **between** the `1000p` and the terminating ST. The existing tests in `control.zig` construct a `Parser` and push bytes, collecting `Notification`s; follow that exact pattern (read the file's existing tests first to copy the precise `Parser` init/push/collect API names — do not invent them).

- [ ] **Step 1: Inspect the existing parser test API**

Run:
```bash
cd /Users/evan/.leo/agents/leoterm
grep -n "test \"" src/terminal/tmux/control.zig | head
sed -n '/test "/,/^}/p' src/terminal/tmux/control.zig | head -60
```
Note the exact function/field names used to: create a `Parser`, feed bytes, and read out `Notification` values (e.g. how a test drives `parser` and asserts a `.session_changed` / `.output` / `.exit`). Use those names verbatim in Step 2.

- [ ] **Step 2: Write the failing test**

Append to `src/terminal/tmux/control.zig` (adapt the Parser-driving calls to match the names found in Step 1; the assertions below are the contract):

```zig
test "parses real leo agent -CC transcript" {
    const alloc = std.testing.allocator;

    // Raw capture of `tmux -L leo -CC attach -t leo-leoterm`, DCS-wrapped.
    const raw = @embedFile("testdata/leo-agent-attach-CC.bin");

    // Strip the DCS envelope: bytes between "1000p" and the terminating ST
    // (ESC '\'). dcs.zig does this in the real pipeline; here we do it inline
    // so the Parser receives exactly the control-mode line stream it expects.
    const open = std.mem.indexOf(u8, raw, "1000p") orelse return error.NoDcsOpen;
    const inner_start = open + "1000p".len;
    const st = std.mem.indexOfPos(u8, raw, inner_start, "\x1b\\") orelse raw.len;
    const inner = raw[inner_start..st];

    var parser: Parser = try .init(alloc); // adjust to real init from Step 1
    defer parser.deinit();

    var saw_session_changed = false;
    var saw_output_pane_25 = false;
    var saw_exit = false;

    // Drive the parser over the inner stream, collecting notifications.
    // Replace `pushAll`/iteration with the real API names from Step 1.
    var it = parser.pushAll(inner); // adjust to real API
    while (try it.next()) |notif| {
        switch (notif) {
            .session_changed => |s| {
                saw_session_changed = true;
                try std.testing.expect(std.mem.indexOf(u8, s.name, "leo-leoterm") != null);
            },
            .output => |o| {
                if (o.pane_id == 25) saw_output_pane_25 = true;
            },
            .exit => saw_exit = true,
            else => {},
        }
    }

    try std.testing.expect(saw_session_changed);
    try std.testing.expect(saw_output_pane_25);
    try std.testing.expect(saw_exit);
}
```

> Note: the pane id in the capture is `%25` and the session is `$25 leo-leoterm`. If the parser exposes session name including/excluding the leading `$`, assert with `indexOf` as above to stay robust.

- [ ] **Step 3: Run test to verify it fails (then iterate API names to green-or-fail-for-the-right-reason)**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="real leo agent -CC transcript" 2>&1 | tail -30
```
Expected first run: a **compile** error if the placeholder API names (`pushAll`, `it.next`, `Parser.init`) don't match the real ones from Step 1. Fix the API calls to match the real parser. Then the expected state is a clean PASS if the parser already handles this stream (it should — these notification types are covered by the existing 18 tests). If it fails an assertion, that's a real parser gap worth reporting, not a test bug.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="real leo agent -CC transcript" 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/tmux/control.zig src/terminal/tmux/testdata/leo-agent-attach-CC.bin
git commit -m "test(tmux): parse real leo agent -CC control-mode transcript fixture"
```

---

## Task 3: Mirror the active pane into the host surface terminal (the `.windows` TODO)

Implements native rendering: after the `Viewer` populates a pane's `Terminal`, copy its active screen into the **host surface's** `Terminal` (the one the Metal renderer already draws via `renderer_state.terminal`). This is the single-pane render path. We isolate the copy in a pure, unit-tested helper (`mirror.zig`) so correctness is proven headlessly, then wire it into `stream_handler.zig` with a few lines following existing patterns.

**Files:**
- Create: `src/terminal/tmux/mirror.zig`
- Modify: `src/terminal/tmux.zig` (export `mirror`)
- Modify: `src/terminal/tmux/viewer.zig` (add `activePaneTerminal()` accessor + test)
- Modify: `src/termio/stream_handler.zig` (implement `.windows`)

**Background (verified):**
- Each `Viewer.Pane` owns a full `terminal.Terminal` (`viewer.zig:256`), populated from `%output` + capture-pane. Panes live in `viewer.panes` (`AutoArrayHashMapUnmanaged(usize, Pane)`); the window layout tree (`Window.layout`, a `Layout` with `.content` = `.pane: usize` | `.horizontal`/`.vertical` splits) maps window → pane id.
- `Screen.clone(alloc, top, bot)` (`Screen.zig:442`) deep-clones a screen region. `Screen.dumpStringAlloc(alloc, .{ .history = .{} })` (`Screen.zig:3185`) gives a comparable string (used by viewer tests).
- `ScreenSet` has `active: *Screen` and `get(key)`/`switchScreen(key)`; a `Terminal` has `screens: ScreenSet`, `cols`, `rows`.
- In `stream_handler.zig` the `.windows` handler has in scope: `self.terminal: *terminal.Terminal` (the host surface terminal), `self.renderer_state: *renderer.State` (`.mutex`, `.terminal`), `self.renderer_mailbox`, `self.alloc`, and `viewer` (`*Viewer`).

### Subtask 3a: `Viewer.activePaneTerminal()` accessor

- [ ] **Step 1: Write the failing test** — append to `src/terminal/tmux/viewer.zig` test block:

```zig
test "activePaneTerminal returns the single pane's terminal" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    // Drive the minimal startup → single pane → output sequence. Reuse the
    // helper/steps from the existing "initial flow" test (copy its TestStep
    // sequence up to the point one pane exists and has output "Hello, world!").
    // <-- Insert the same notification steps the "initial flow" test uses to
    //     reach a populated pane id 0; see test "initial flow" above. -->

    const t = viewer.activePaneTerminal() orelse return error.NoActivePane;
    const str = try t.screens.active.dumpStringAlloc(alloc, .{ .history = .{} });
    defer alloc.free(str);
    try testing.expect(std.mem.indexOf(u8, str, "Hello, world!") != null);
}
```

> Implementation note for the executor: rather than hand-copy the notification steps, factor the "initial flow" test's setup into a small private helper `fn setupSinglePane(viewer: *Viewer) !void` and call it from both that test and this one (DRY). The existing test already asserts pane 0 contains `"Hello, world!"`, so the steps are known-good.

- [ ] **Step 2: Run to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="activePaneTerminal" 2>&1 | tail -20
```
Expected: FAIL — `activePaneTerminal` not defined.

- [ ] **Step 3: Implement the accessor** — add to `viewer.zig` (public methods section):

```zig
/// Returns the Terminal of the active pane of the active window, or null if
/// no pane is available yet. For the common single-window/single-pane case
/// this is the only pane. For multi-pane windows this returns the first pane
/// found in layout order (active-pane tracking is a future enhancement).
pub fn activePaneTerminal(self: *Viewer) ?*Terminal {
    const window = if (self.windows.items.len > 0) self.windows.items[0] else return null;
    const pane_id = firstPaneId(window.layout) orelse return null;
    const entry = self.panes.getEntry(pane_id) orelse return null;
    return &entry.value_ptr.terminal;
}

/// Depth-first walk of a layout tree returning the first pane leaf's id.
fn firstPaneId(node: Layout) ?usize {
    return switch (node.content) {
        .pane => |id| id,
        .horizontal, .vertical => |children| {
            for (children) |child| {
                if (firstPaneId(child)) |id| return id;
            }
            return null;
        },
    };
}
```

> Verify field names against the file: `self.windows` is the window list (`viewer.zig` struct field), `Layout.content` is the union from `layout.zig`. Adjust `self.windows.items` if the windows collection is not a plain `ArrayList` (check the struct definition near `viewer.zig:181`).

- [ ] **Step 4: Run to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="activePaneTerminal" 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): Viewer.activePaneTerminal accessor for single-pane render"
```

### Subtask 3b: `mirror.zig` pure helper

- [ ] **Step 1: Write the failing test** — create `src/terminal/tmux/mirror.zig`:

```zig
//! Mirrors a tmux Viewer's active pane screen into a destination Terminal so
//! the existing renderer (which draws `renderer_state.terminal`) displays the
//! pane natively. The destination keeps its own identity; we overwrite the
//! contents of its active screen with a clone of the pane's active screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("../Terminal.zig");
const Viewer = @import("viewer.zig").Viewer;

/// Copy the active pane's active screen from `viewer` into `dst`.
/// Returns false if there is no active pane yet (caller should leave dst as-is).
/// The caller MUST hold any lock guarding `dst` (e.g. renderer_state.mutex).
pub fn mirrorActivePane(alloc: Allocator, viewer: *Viewer, dst: *Terminal) !bool {
    const src_term = viewer.activePaneTerminal() orelse return false;
    const src = src_term.screens.active;

    // Clone the full pane screen (history through bottom-right).
    var cloned = try src.clone(alloc, .{ .history = .{} }, null);
    errdefer cloned.deinit(alloc);

    // Replace dst's active screen contents with the clone.
    dst.screens.active.deinit(alloc);
    dst.screens.active.* = cloned;

    // Keep the Terminal's dimensions consistent with the screen we installed
    // so the renderer's geometry math matches the cells it draws.
    dst.cols = src_term.cols;
    dst.rows = src_term.rows;
    return true;
}

test "mirrorActivePane copies pane content into destination terminal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    // Reuse the shared single-pane setup helper from viewer.zig tests.
    try Viewer.setupSinglePane(&viewer); // make this helper pub for tests

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);

    const ok = try mirrorActivePane(alloc, &viewer, &dst);
    try testing.expect(ok);

    const got = try dst.screens.active.dumpStringAlloc(alloc, .{ .history = .{} });
    defer alloc.free(got);

    const want_term = viewer.activePaneTerminal().?;
    const want = try want_term.screens.active.dumpStringAlloc(alloc, .{ .history = .{} });
    defer alloc.free(want);

    try testing.expectEqualStrings(want, got);
}

test "mirrorActivePane returns false when no pane exists" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);
    try testing.expect((try mirrorActivePane(alloc, &viewer, &dst)) == false);
}
```

> The `clone(alloc, top, bot)` argument shape and the `Screen` deinit/assignment must match `Screen.zig:442`. The exact `point.Point` value for "from history top" is `.{ .history = .{} }` per `dumpStringAlloc` usage; confirm against `Screen.clone`'s callers (e.g. selection/alt-screen clone sites — `grep -n "\.clone(" src/terminal/*.zig`). The destination-screen replacement (`deinit` + assign clone) is the RED/GREEN target; if in-place pointer reassignment fights `ScreenSet` invariants, the alternative is to clone into a temp, `dst.screens.active.* = undefined`-free swap, or expose a `ScreenSet.replaceActive`. Let the two tests above drive the exact mechanism.

- [ ] **Step 2: Export from `tmux.zig`** — add to `src/terminal/tmux.zig`:

```zig
pub const mirror = @import("tmux/mirror.zig");
```

- [ ] **Step 3: Run to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="mirrorActivePane" 2>&1 | tail -30
```
Expected: FAIL/compile-error initially. Iterate the screen-replacement mechanism and `clone` args until both tests PASS. The `expectEqualStrings(want, got)` assertion is the correctness contract.

- [ ] **Step 4: Run to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="mirrorActivePane" 2>&1 | tail -10
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/terminal/tmux/mirror.zig src/terminal/tmux.zig src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): mirror active pane screen into destination terminal"
```

### Subtask 3c: Wire mirror into the `.windows` handler

- [ ] **Step 1: Implement the `.windows` action** — in `src/termio/stream_handler.zig`, replace the `.windows => { // TODO }` block (around line 458) with:

```zig
.windows => {
    // Mirror the active pane's screen into the surface terminal under
    // the renderer lock, then mark dirty and wake the renderer so it
    // redraws from the mirrored content.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const mirrored = terminal.tmux.mirror.mirrorActivePane(
        self.alloc,
        viewer,
        self.terminal,
    ) catch |err| mirrored: {
        log.warn("tmux mirror failed: {}", .{err});
        break :mirrored false;
    };
    if (mirrored) {
        self.terminal.flags.dirty.clear = true;
        try self.queueRender();
    }
},
```

> Confirm the exact field for "the surface terminal" in `StreamHandler` (`self.terminal`), the dirty-flag path (`self.terminal.flags.dirty.clear` — check `Terminal.zig` flags struct), and the render-wake call. The existing `.command` arm already calls `self.messageWriter(...)`; for waking the renderer find how other handlers request a redraw (grep `queueRender`/`renderer_mailbox`/`wakeup` in `stream_handler.zig`) and use the established call. Replace `try self.queueRender();` with the real one.

- [ ] **Step 2: Also handle `.exit`** — in the same switch, replace the `.exit => { ... ignore ... }` comment-only arm so it resets the host terminal to a clean state (so a detached/exited agent cell doesn't freeze on stale pane content):

```zig
.exit => {
    // The control-mode session ended. Leave a clear, mutex-guarded
    // terminal so the cell shows empty rather than a frozen pane.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.fullReset();
    self.terminal.flags.dirty.clear = true;
    try self.queueRender();
},
```

> Confirm `Terminal.fullReset()` exists (grep in `Terminal.zig`); if the name differs use the real reset. Keep the existing DCS-level `.exit` viewer teardown (the `switch (tmux)` `.exit` arm earlier in the function that frees `self.tmux_viewer`) — this new arm is inside the `for (viewer.next(...)) |action|` loop and handles the **viewer action**, not the DCS command.

- [ ] **Step 3: Build-verify the core (no GUI)**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build -Demit-macos-app=false 2>&1 | tail -20
```
Expected: builds with no errors. (This proves the wiring compiles; on-screen behavior is hand-verified at the end.)

- [ ] **Step 4: Run the full tmux test group to confirm no regressions**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="tmux" 2>&1 | tail -15
```
Expected: all tmux tests PASS (the original 114 + the new ones).

- [ ] **Step 5: Commit**

```bash
git add src/termio/stream_handler.zig
git commit -m "feat(tmux): render active pane by mirroring into surface terminal (.windows)"
```

---

## Task 4: Input + resize back-path (host keystrokes/resize → tmux)

The `Viewer.Input` union currently only has `.tmux` (incoming notifications) — there is **no** way to send keystrokes or resize to tmux. We add `Input.keys` and `Input.resize` that produce `.command` actions (`send-keys` / `refresh-client`), following the viewer's existing command-emission pattern, then forward host-surface keystrokes/resize into the viewer from `stream_handler.zig`.

**Files:**
- Modify: `src/terminal/tmux/viewer.zig` (extend `Input`, emit commands, tests)
- Modify: `src/termio/stream_handler.zig` (forward keystrokes + resize to the viewer)

**Background (verified):** the viewer emits `.command: []const u8` actions (with trailing `\n`) that `stream_handler` sends to tmux verbatim via `self.messageWriter(termio.Message.writeReq(...))`. tmux `send-keys -t %<pane> -l -- <literal>` sends literal bytes to a pane; `refresh-client -C <cols>x<rows>` (tmux ≥ 2.4) sets the control client's pane size, which makes tmux resize the pane and emit a `%layout-change` (re-syncing pane dimensions through the normal path). Pane ids in this protocol are the `%<n>` values (e.g. `%25`); the viewer already tracks pane ids as `usize` keys in `viewer.panes`.

### Subtask 4a: `Input.keys` → `send-keys`

- [ ] **Step 1: Write the failing test** — append to `viewer.zig` tests:

```zig
test "keys input emits send-keys command for active pane" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try Viewer.setupSinglePane(&viewer); // pane id 0 exists

    const actions = viewer.next(.{ .keys = "ls\r" });
    var found: ?[]const u8 = null;
    for (actions) |a| switch (a) {
        .command => |c| found = c,
        else => {},
    };
    const cmd = found orelse return error.NoCommand;
    // Literal send-keys to the active pane, bytes passed with -l, trailing \n.
    try testing.expect(std.mem.startsWith(u8, cmd, "send-keys -t %0 -l -- "));
    try testing.expect(std.mem.indexOf(u8, cmd, "ls\r") != null);
    try testing.expect(cmd[cmd.len - 1] == '\n');
}

test "keys input with no active pane emits nothing" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    const actions = viewer.next(.{ .keys = "x" });
    try testing.expectEqual(@as(usize, 0), actions.len);
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="send-keys command" 2>&1 | tail -20
```
Expected: FAIL — `Input` has no `.keys` field.

- [ ] **Step 3: Implement** — in `viewer.zig`:

1. Extend the `Input` union:
```zig
pub const Input = union(enum) {
    /// Data from tmux was received that needs to be processed.
    tmux: control.Notification,
    /// Literal key bytes from the host surface to forward to the active pane.
    keys: []const u8,
    /// The host surface was resized; cols/rows are the new grid size.
    resize: struct { cols: usize, rows: usize },
};
```

2. In `next()`, dispatch the new variants. For `.keys`, find the active pane id (reuse `firstPaneId(self.windows.items[0].layout)`), then build a `send-keys` command into the viewer's action arena and return it as a single `.command` action. Mirror how existing handshake commands are allocated/returned (the viewer formats commands into `action_arena` and returns an `Action{ .command = ... }` slice). Concretely:

```zig
.keys => |bytes| {
    const window = if (self.windows.items.len > 0) self.windows.items[0] else return &.{};
    const pane_id = firstPaneId(window.layout) orelse return &.{};
    const arena = self.action_arena.allocator(); // match the real arena field name
    const cmd = std.fmt.allocPrint(
        arena,
        "send-keys -t %{d} -l -- {s}\n",
        .{ pane_id, bytes },
    ) catch return &.{};
    const actions = arena.alloc(Action, 1) catch return &.{};
    actions[0] = .{ .command = cmd };
    return actions;
},
```

> Match the real action-arena field/return convention in `viewer.zig` (grep how `.command` actions are currently built and returned, e.g. in the startup/handshake path — copy that allocation idiom exactly). `send-keys -l -- <bytes>` sends bytes literally; the `--` guards bytes that start with `-`.

- [ ] **Step 4: Run to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="send-keys command" 2>&1 | tail -10
zig build test-lib-vt -Dtest-filter="no active pane emits nothing" 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): Viewer.Input.keys emits send-keys for active pane"
```

### Subtask 4b: `Input.resize` → `refresh-client -C`

- [ ] **Step 1: Write the failing test** — append to `viewer.zig` tests:

```zig
test "resize input emits refresh-client size command" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try Viewer.setupSinglePane(&viewer);

    const actions = viewer.next(.{ .resize = .{ .cols = 120, .rows = 40 } });
    var found: ?[]const u8 = null;
    for (actions) |a| switch (a) {
        .command => |c| found = c,
        else => {},
    };
    const cmd = found orelse return error.NoCommand;
    try testing.expect(std.mem.startsWith(u8, cmd, "refresh-client -C 120x40"));
    try testing.expect(cmd[cmd.len - 1] == '\n');
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="refresh-client size command" 2>&1 | tail -20
```
Expected: FAIL.

- [ ] **Step 3: Implement** — add the `.resize` arm in `next()`:

```zig
.resize => |sz| {
    if (self.windows.items.len == 0) return &.{};
    const arena = self.action_arena.allocator();
    const cmd = std.fmt.allocPrint(
        arena,
        "refresh-client -C {d}x{d}\n",
        .{ sz.cols, sz.rows },
    ) catch return &.{};
    const actions = arena.alloc(Action, 1) catch return &.{};
    actions[0] = .{ .command = cmd };
    return actions;
},
```

- [ ] **Step 4: Run to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="refresh-client size command" 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): Viewer.Input.resize emits refresh-client -C command"
```

### Subtask 4c: Forward host keystrokes + resize from the stream handler

When the surface is in tmux-viewer mode, host keystrokes must go to tmux (not the local PTY shell, which is the `tmux -CC` client process). The stream handler's tmux_viewer is the signal that we're in viewer mode.

- [ ] **Step 1: Find where surface input/resize reach termio**

```bash
cd /Users/evan/.leo/agents/leoterm
grep -n "queueWrite\|pub fn write\|resize\|pub fn changeScreenSize\|fn parse\|fn process" src/termio/Termio.zig | head -30
grep -n "tmux_viewer\|messageWriter\|fn dcsCommand\|fn process" src/termio/stream_handler.zig | head
```
Identify (a) the function that handles outbound user writes (the path that today does `queueWrite` to the pty — likely `Termio.queueWrite` / a `write` message) and (b) the resize entry (`changeScreenSize` or similar). The goal: when `stream_handler.tmux_viewer != null`, route those through `viewer.next(.{ .keys = ... })` / `.resize` and send the resulting `.command` actions to tmux via `messageWriter`, instead of (or in addition to) the default pty write.

- [ ] **Step 2: Add a helper on StreamHandler to drain viewer actions**

Factor the existing action loop (from Task 3) into a reusable method so keystroke/resize forwarding shares it. In `stream_handler.zig`:

```zig
/// Feed an input to the tmux viewer (if active) and dispatch its actions.
/// Returns true if the viewer consumed the input (caller should NOT also
/// send it down the normal pty path).
fn tmuxViewerInput(self: *StreamHandler, input: terminal.tmux.Viewer.Input) !bool {
    if (comptime !tmux_enabled) return false;
    const viewer = self.tmux_viewer orelse return false;
    for (viewer.next(input)) |action| {
        switch (action) {
            .command => |command| self.messageWriter(try termio.Message.writeReq(self.alloc, command)),
            .exit, .windows => {}, // handled elsewhere / not expected from keys/resize
        }
    }
    return true;
}
```

> Place this near the existing viewer action handling so both share the action switch where practical (DRY — if the `.windows`/`.exit` rendering logic is needed here too, extract a single `dispatchAction` switch and call it from both the DCS path and this helper).

- [ ] **Step 3: Route keystrokes and resize through it**

At the outbound-write site identified in Step 1 (where user-typed bytes are about to be queued to the pty), gate on the viewer:

```zig
// When a tmux control-mode viewer is active, host keystrokes belong to the
// remote pane, not the local -CC client process.
if (try self.tmuxViewerInput(.{ .keys = data })) return;
```

At the resize site:

```zig
if (self.tmux_viewer != null) {
    _ = try self.tmuxViewerInput(.{ .resize = .{ .cols = grid_size.columns, .rows = grid_size.rows } });
    // Fall through to also resize the local terminal so the mirror geometry
    // tracks the surface; the pane resize completes asynchronously via the
    // %layout-change tmux sends back.
}
```

> The exact field names (`grid_size.columns`/`.rows`, the data slice variable, the function bodies these snippets land in) must be matched to the real `stream_handler.zig` / `Termio.zig` signatures from Step 1. Keep edits surgical.

- [ ] **Step 4: Build-verify**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build -Demit-macos-app=false 2>&1 | tail -20
```
Expected: clean build.

- [ ] **Step 5: Run all tmux tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build test-lib-vt -Dtest-filter="tmux" 2>&1 | tail -15
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/termio/stream_handler.zig
git commit -m "feat(tmux): forward host keystrokes/resize to tmux when viewer active"
```

---

## Task 5: Build the macOS app and hand off for visual verification

The logic is proven headlessly; this task produces the actual app for Evan to verify on-screen (the agent session cannot — see `gui-verification-constraint`).

**Files:** none (build + docs only).

- [ ] **Step 1: Full build of the macOS app**

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd /Users/evan/.leo/agents/leoterm
zig build -Demit-macos-app=true -Demit-xcframework=true 2>&1 | tail -20
```
Expected: builds `macos/build/Debug/Ghostty.app` (or the xcframework path used by the macOS project). If the build uses `xcodebuild`, pass `-packageAuthorizationProvider netrc` (Sparkle SPM gotcha).

- [ ] **Step 2: Final swiftlint gate**

```bash
cd macos && swiftlint lint --strict --quiet
```
Expected: clean.

- [ ] **Step 3: Push and write the verification handoff**

```bash
git push -u origin HEAD
```

Then provide Evan these exact manual-verification steps (a temporary route to create an agent cell is acceptable for this phase — full sidebar/palette is Phase 4):

1. Launch the built app.
2. Open a cell whose `CellSource` is `.agent(name: "leoterm")` (or any running agent from `leo agent list --json`). Until Phase 4 wires the palette, expose a temporary debug entry point (e.g. a menu item or a hardcoded first-cell source) that creates a surface with `CellSource.agent(name:).surfaceConfiguration`.
3. **Expect:** the cell renders the agent's live Claude Code TUI natively (not raw `%output` text).
4. Type into the cell — keystrokes should reach the agent (e.g. arrow keys/enter move its UI).
5. Hover-grow / resize the cell — the agent's content should reflow to the new size (after the tmux `%layout-change` round-trip).
6. Detaching/closing the cell should leave the agent running in the daemon (`leo agent list --json` still shows it `running`).

- [ ] **Step 4: Report results**

Tell Evan: what built, which headless tests pass (counts), and the precise manual checklist above. Do not claim visual correctness — that is Evan's to confirm.

---

## Self-Review

**Spec coverage (against `docs/superpowers/specs/2026-06-08-leo-terminal-design.md` §2.2, §2.3, §8.3, §9):**
- §2.2 `CellSource` protocol with `PTYSource` + `TmuxControlSource` → **Task 1** (`CellSource.pty` / `.agent`). Naming note: the spec says "TmuxControlSource"; we realize it as `CellSource.agent` because the actual control-mode client is the in-core `Viewer` (the spec predates discovering upstream shipped it). The Swift abstraction still cleanly separates plain vs agent cells per the spec's intent.
- §2.3 "parses control-mode notifications" → already in-tree + **Task 2** real-transcript test.
- §2.3 "maps tmux panes to Ghostty surfaces, feeds pane output" → **Task 3** (mirror active pane → host surface).
- §2.3 "sends input and resize back to tmux" → **Task 4**.
- §2.3 open question "one server vs many" → **resolved in this plan's header**: one server (`-L leo`), one session per agent; client handles the single-pane case natively.
- §8.3 "attach to one agent and render it natively" → **Tasks 3–5**.
- §9 "control-mode protocol parser (fixture-driven)" → **Task 2**; "TmuxControlSource against a real `tmux -CC` session" → **Task 5** manual verification (the live daemon).

**Deliberate scope boundaries (logged, not silently dropped):**
- Multi-pane / multi-window tmux windows render only the **active/first pane**. Leo agents are 1-pane today; tiling panes into sub-cells is deferred to Phase 6. `activePaneTerminal` documents this.
- `%bell`/status surfacing to cell chrome is **Phase 5**, not here. The viewer already parses these; Phase 5 consumes them.
- The temporary debug entry point for creating an agent cell (Task 5) is replaced by the Phase 4 sidebar/palette.

**Placeholder scan:** Implementation snippets that touch unverified internal field/method names (`self.queueRender`, `self.action_arena`, `Terminal.fullReset`, `self.windows.items`, the outbound-write/resize sites) are explicitly flagged with a "confirm against the real file" note and a grep to find the real name — these are TDD targets where the test is the contract, not hand-waving. No "TBD"/"implement later"/"add error handling" placeholders remain.

**Type consistency:** `CellSource` (Task 1) — `.pty` / `.agent(name:)`, `surfaceConfiguration`, `isAgent`. `Viewer.activePaneTerminal()` (3a) is consumed by `mirror.mirrorActivePane` (3b) and `Input.keys`/`.resize` (4a/4b). `mirrorActivePane(alloc, viewer, dst) !bool` signature matches its call site in `stream_handler.zig` (3c). `Viewer.Input` gains `.keys: []const u8` and `.resize: struct{cols,rows}`, consumed identically in 4a/4b/4c. `Viewer.setupSinglePane` is introduced as a shared test helper in 3a and reused in 3b/4a/4b.
