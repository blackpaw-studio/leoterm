//! Mirrors a tmux Viewer's active pane screen into a destination Terminal so
//! the existing renderer (which draws `renderer_state.terminal`) displays the
//! pane natively. The destination keeps its own identity; we overwrite the
//! contents of its active screen with a clone of the pane's active screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ScreenSet = @import("../ScreenSet.zig");
const Tabstops = @import("../Tabstops.zig");
const Terminal = @import("../Terminal.zig");
const Viewer = @import("viewer.zig").Viewer;
const testing = std.testing;

/// Copy the active pane's active screen from `viewer` into `dst`.
///
/// Returns false if there is no active pane yet (caller leaves `dst` as-is).
/// The caller MUST hold any lock guarding `dst` (e.g. renderer_state.mutex).
///
/// The destination's active screen contents are replaced with a full clone
/// (including scrollback) of the pane's active screen, and `dst.cols`/`dst.rows`
/// are reconciled to the pane's geometry so the renderer draws the cells with
/// matching dimensions.
///
/// NOTE(perf): This performs a full heap clone of the source screen on every
/// call. Callers on the hot %output path should consider rate-limiting or
/// dirty-flagging to avoid per-chunk allocation churn.
/// A representative cell size for tests that don't care about pixels.
const test_cell: CellSize = .{ .width = 10, .height = 20 };

/// The pixel dimensions of a single terminal cell, used to keep the
/// destination's pixel geometry consistent with its new grid size.
pub const CellSize = struct {
    width: u32,
    height: u32,
};

pub fn mirrorActivePane(
    alloc: Allocator,
    viewer: *Viewer,
    dst: *Terminal,
    cell: CellSize,
) !bool {
    const src_term = viewer.activePaneTerminal() orelse return false;

    // A degenerate pane geometry would underflow the scrolling-region math
    // below (`cols - 1` / `rows - 1`) and can't be rendered anyway.
    if (src_term.cols == 0 or src_term.rows == 0) return false;

    // Track which screen the pane considers active. Interleaved raw output
    // and mode queries on the host terminal must agree with the pane about
    // whether we're on the alternate screen; without this a pane in a
    // full-screen TUI mirrors its alt screen onto the host's primary.
    // Fallible, and done before any state is swapped, so a failure leaves
    // `dst` untouched and self-consistent.
    if (dst.screens.active_key != src_term.screens.active_key) {
        _ = try dst.switchScreen(src_term.screens.active_key);
    }

    const src_screen = src_term.screens.active;

    // Clone the full source screen (scrollback included). `.screen` starts at
    // the top of the scrollback; a null bottom means "to the end".
    var clone = try src_screen.clone(alloc, .{ .screen = .{} }, null);
    errdefer clone.deinit();

    // All fallible reconciliation happens BEFORE the in-place screen swap so
    // an error (OOM) leaves `dst` in its previous, self-consistent state.

    // Non-active screens keep their old geometry through the swap below, but
    // switchScreen reuses them without resizing; they must match the new
    // cols/rows or a later alt-screen switch (from interleaved raw output)
    // leaves the terminal geometry inconsistent with its active screen.
    inline for (@typeInfo(ScreenSet.Key).@"enum".fields) |field| {
        const key: ScreenSet.Key = @enumFromInt(field.value);
        if (key != dst.screens.active_key) {
            if (dst.screens.get(key)) |screen| try screen.resize(.{
                .cols = src_term.cols,
                .rows = src_term.rows,
                .reflow = false,
            });
        }
    }

    // Tabstops are sized to the column count (same as Terminal.resize); stale
    // ones would be out of range for cursor positions in the new geometry.
    if (dst.cols != src_term.cols) {
        var tabstops: Tabstops = try .init(alloc, src_term.cols, 8);
        errdefer tabstops.deinit(alloc);
        dst.tabstops.deinit(alloc);
        dst.tabstops = tabstops;
    }

    // Replace the destination's active screen. `ScreenSet.replace` deinits the
    // old screen (freeing its pages) and moves the clone into the same heap
    // slot that `dst.screens.active` already points at, so the ScreenSet's
    // `active`/`active_key`/`all` invariants hold: pointer identity is
    // preserved, only the pointee changes.
    //
    // Critically, it also bumps the screen's generation. The old screen's pin
    // pool is destroyed here, so every tracked pin into it is dangling. The
    // generation is the ONLY signal of that, precisely because the pointer
    // doesn't change; holders that compare pointers alone (the search thread
    // did) will happily keep using freed pins. Everything that retains pins
    // across frames must compare `ScreenSet.generation` — currently
    // `SelectionGesture`, `search.ScreenSearch` and the C API grid refs.
    dst.screens.replace(dst.screens.active_key, clone);

    // Reconcile the terminal-level geometry with the screen we just installed
    // so the renderer's cols/rows match the cells it draws.
    dst.cols = src_term.cols;
    dst.rows = src_term.rows;

    // Pixel geometry is reported to the app via CSI 14 t / ioctl and must
    // track the grid (same invariant Termio.resize maintains). Leaving it at
    // the pre-mirror size makes in-pane pixel queries and mouse-pixel
    // reporting wrong.
    dst.width_px = @as(u32, @intCast(dst.cols)) * cell.width;
    dst.height_px = @as(u32, @intCast(dst.rows)) * cell.height;

    // Carry over the pane's cursor visibility (DECTCEM). A pane that hid its
    // cursor (e.g. a full-screen TUI) must not show the host's cursor over
    // the mirrored content.
    dst.modes.set(.cursor_visible, src_term.modes.get(.cursor_visible));

    // Keep the alt-screen mode bits in agreement with the active screen key
    // we followed above; otherwise `modes` and `screens.active_key` disagree
    // and a DECRQM report contradicts what is on screen. All three are
    // copied because we don't know which one the pane's app used.
    inline for (.{
        .alt_screen_legacy,
        .alt_screen,
        .alt_screen_save_cursor_clear_enter,
    }) |mode| dst.modes.set(mode, src_term.modes.get(mode));

    // The scrolling region must track the new geometry (same as
    // Terminal.resize). A stale bottom beyond the new row count lets
    // Terminal.index step the cursor past the end of the screen — an
    // assertion crash on the next raw newline that reaches this terminal.
    dst.scrolling_region = .{
        .top = 0,
        .bottom = dst.rows - 1,
        .left = 0,
        .right = dst.cols - 1,
    };

    return true;
}

test "tmux mirrorActivePane copies pane content into destination terminal" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // receivedPaneState restores the pane's active screen to its real mode
    // (primary, where "Hello, world!" lives) after the capture-pane replay,
    // so mirrorActivePane clones real content with no manual switch needed.
    const pane = viewer.activePaneTerminal().?;

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);

    const ok = try mirrorActivePane(alloc, &viewer, &dst, test_cell);
    try testing.expect(ok);

    // Real content was copied, not an empty screen.
    const got = try dst.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "Hello, world!") != null);

    // And faithful: dst active dump equals the source pane active dump.
    const want = try pane.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(want);
    try testing.expectEqualStrings(want, got);

    // Geometry reconciled to the pane.
    try testing.expectEqual(pane.cols, dst.cols);
    try testing.expectEqual(pane.rows, dst.rows);
}

test "tmux mirrorActivePane returns false when no pane exists" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);

    try testing.expect((try mirrorActivePane(alloc, &viewer, &dst, test_cell)) == false);
}

test "tmux mirrorActivePane reconciles scrolling region to pane geometry" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // Destination is taller than the 80x24 pane, like a real surface whose
    // grid was sized before control mode attached. Its scrolling region
    // covers all 52 rows.
    var dst: Terminal = try .init(alloc, .{ .cols = 100, .rows = 52 });
    defer dst.deinit(alloc);
    try testing.expectEqual(@as(usize, 51), dst.scrolling_region.bottom);

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));

    // The scrolling region must track the new geometry. A stale bottom (51)
    // beyond rows (24) lets Terminal.index call Screen.cursorDown past the
    // end of the screen: an assertion crash on the next raw newline that
    // reaches the surface terminal (e.g. interleaved non-control output).
    try testing.expectEqual(@as(usize, 0), dst.scrolling_region.top);
    try testing.expectEqual(dst.rows - 1, dst.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), dst.scrolling_region.left);
    try testing.expectEqual(dst.cols - 1, dst.scrolling_region.right);
}

test "tmux mirrorActivePane reconciles tabstops to pane width" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // Destination narrower than the 80-col pane: tabstops sized for 40
    // columns would be out of range for cursor positions in the mirrored
    // geometry.
    var dst: Terminal = try .init(alloc, .{ .cols = 40, .rows = 24 });
    defer dst.deinit(alloc);

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));

    try testing.expectEqual(@as(usize, dst.cols), dst.tabstops.cols);
}

test "tmux mirrorActivePane resizes non-active screens to pane geometry" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 100, .rows = 52 });
    defer dst.deinit(alloc);

    // Materialize an alternate screen at the old geometry, then go back to
    // primary before mirroring.
    _ = try dst.switchScreen(.alternate);
    _ = try dst.switchScreen(.primary);

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));

    // If interleaved raw output later enters alt-screen mode, switchScreen
    // reuses the existing screen without resizing; it must already match the
    // terminal's cols/rows or the renderer/cursor state goes inconsistent.
    const alt = dst.screens.get(.alternate).?;
    try testing.expectEqual(@as(usize, dst.rows), alt.pages.rows);
    try testing.expectEqual(@as(usize, dst.cols), alt.pages.cols);
}

test "tmux mirrorActivePane bumps the destination screen generation" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);

    const before = dst.screens.generation(dst.screens.active_key);

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));

    // The mirror destroys the old screen's pin pool. Holders of tracked pins
    // (selection gestures, search, C API grid refs) only detect that via the
    // generation counter; without the bump they write into freed memory.
    try testing.expectEqual(
        before +% 1,
        dst.screens.generation(dst.screens.active_key),
    );
}

test "tmux mirrorActivePane returns false for degenerate pane geometry" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);

    // A zero-width pane would underflow the `cols - 1` scrolling region math.
    viewer.activePaneTerminal().?.cols = 0;
    try testing.expect((try mirrorActivePane(alloc, &viewer, &dst, test_cell)) == false);

    viewer.activePaneTerminal().?.cols = 80;
    viewer.activePaneTerminal().?.rows = 0;
    try testing.expect((try mirrorActivePane(alloc, &viewer, &dst, test_cell)) == false);
}

test "tmux mirrorActivePane keeps pixel geometry consistent with the grid" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 100, .rows = 52 });
    defer dst.deinit(alloc);
    dst.width_px = 100 * test_cell.width;
    dst.height_px = 52 * test_cell.height;

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));

    // The pixel size tracks the new grid at the caller's authoritative cell
    // size (same invariant Termio.resize maintains) so CSI 14 t and pixel
    // mouse reporting stay correct inside the mirrored pane.
    try testing.expectEqual(@as(u32, 80 * 10), dst.width_px);
    try testing.expectEqual(@as(u32, 24 * 20), dst.height_px);
}

test "tmux mirrorActivePane copies cursor visibility from the pane" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);
    try testing.expect(dst.modes.get(.cursor_visible));

    // A pane running a full-screen TUI hides its cursor (DECTCEM). The host
    // must not draw a cursor over the mirrored content.
    viewer.activePaneTerminal().?.modes.set(.cursor_visible, false);
    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));
    try testing.expect(!dst.modes.get(.cursor_visible));

    viewer.activePaneTerminal().?.modes.set(.cursor_visible, true);
    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));
    try testing.expect(dst.modes.get(.cursor_visible));
}

test "tmux mirrorActivePane tracks the pane's active screen key" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);
    try testing.expectEqual(ScreenSet.Key.primary, dst.screens.active_key);

    // Pane enters the alternate screen: the host must follow so interleaved
    // raw output and mode state agree with the content being displayed.
    const pane = viewer.activePaneTerminal().?;
    _ = try pane.switchScreen(.alternate);
    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));
    try testing.expectEqual(ScreenSet.Key.alternate, dst.screens.active_key);

    // And back.
    _ = try pane.switchScreen(.primary);
    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));
    try testing.expectEqual(ScreenSet.Key.primary, dst.screens.active_key);
}

test "tmux mirrorActivePane keeps alt-screen modes agreeing with the screen" {
    const alloc = testing.allocator;

    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    var dst: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer dst.deinit(alloc);

    // The pane's app entered the alt screen via mode 1049.
    const pane = viewer.activePaneTerminal().?;
    _ = try pane.switchScreen(.alternate);
    pane.modes.set(.alt_screen_save_cursor_clear_enter, true);

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));
    try testing.expectEqual(ScreenSet.Key.alternate, dst.screens.active_key);
    try testing.expect(dst.modes.get(.alt_screen_save_cursor_clear_enter));

    // Leaving it must clear the bit too, or a DECRQM report contradicts
    // what's on screen.
    _ = try pane.switchScreen(.primary);
    pane.modes.set(.alt_screen_save_cursor_clear_enter, false);
    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst, test_cell));
    try testing.expectEqual(ScreenSet.Key.primary, dst.screens.active_key);
    try testing.expect(!dst.modes.get(.alt_screen_save_cursor_clear_enter));
}
