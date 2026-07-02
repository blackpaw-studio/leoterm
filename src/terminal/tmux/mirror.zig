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
pub fn mirrorActivePane(alloc: Allocator, viewer: *Viewer, dst: *Terminal) !bool {
    const src_term = viewer.activePaneTerminal() orelse return false;
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

    // Replace the destination's active screen in place. We deinit the old
    // screen first to avoid leaking its pages, then move the clone into the
    // same heap slot that `dst.screens.active` already points at. This keeps
    // the ScreenSet's `active`/`active_key`/`all` invariants intact: the
    // pointer identity is preserved, only the pointee changes.
    const dst_screen = dst.screens.active;
    dst_screen.deinit();
    dst_screen.* = clone;

    // Reconcile the terminal-level geometry with the screen we just installed
    // so the renderer's cols/rows match the cells it draws.
    dst.cols = src_term.cols;
    dst.rows = src_term.rows;

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

    const ok = try mirrorActivePane(alloc, &viewer, &dst);
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

    try testing.expect((try mirrorActivePane(alloc, &viewer, &dst)) == false);
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

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst));

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

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst));

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

    try testing.expect(try mirrorActivePane(alloc, &viewer, &dst));

    // If interleaved raw output later enters alt-screen mode, switchScreen
    // reuses the existing screen without resizing; it must already match the
    // terminal's cols/rows or the renderer/cursor state goes inconsistent.
    const alt = dst.screens.get(.alternate).?;
    try testing.expectEqual(@as(usize, dst.rows), alt.pages.rows);
    try testing.expectEqual(@as(usize, dst.cols), alt.pages.cols);
}
