//! Mirrors a tmux Viewer's active pane screen into a destination Terminal so
//! the existing renderer (which draws `renderer_state.terminal`) displays the
//! pane natively. The destination keeps its own identity; we overwrite the
//! contents of its active screen with a clone of the pane's active screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
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
