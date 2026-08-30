const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const CursorStyle = @import("../cursor.zig").Style;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We need to ignore `output` for panes that aren't yet initialized
//   (until capture-panes are complete).
// - We should note what the active window pane is on the tmux side;
//   we can use this at least for initial focus.

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │            startup_block                    │
///                              │                                             │
///                              │  Wait for initial %begin/%end block from    │
///                              │  tmux. This is the response to the initial  │
///                              │  command (e.g., "attach -t 0").             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %end / %error
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           startup_session                   │
///                              │                                             │
///                              │  Wait for %session-changed notification     │
///                              │  to get the initial session ID.             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %session-changed
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                    ┌───────────────────────────┴───────────────────────────┐
///                    │                  For each new pane:                   │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (primary screen)     │                            │     (primary screen)     │
///     │                          │                            │                          │
///     │  Capture scrollback      │                            │  Capture visible area    │
///     │  history into terminal.  │                            │  into terminal.          │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (alternate screen)   │                            │     (alternate screen)   │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    └───────────────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///
pub const Viewer = struct {
    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// The ID of the session's active window, as last reported by
    /// `%session-window-changed`. Null until tmux tells us (or if the window
    /// is no longer tracked), in which case we fall back to the first window.
    active_window_id: ?usize,

    /// Host input (keystrokes, pastes) that arrived before we had a pane to
    /// route it to. Flushed once list-windows gives us one, so typing into a
    /// still-starting agent cell isn't silently swallowed.
    pending_input: std.ArrayList(u8),

    /// The most recent host grid size that arrived before we had a command
    /// queue to account for its reply block. Flushed when we enter the
    /// command queue. Only the newest size matters.
    pending_resize: ?GridSize,

    /// The active pane of each window, as last reported by
    /// `%window-pane-changed`, keyed by window ID. Windows missing from this
    /// map fall back to the first pane in layout order.
    active_pane_ids: ActivePaneMap,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, Pane);
    pub const ActivePaneMap = std.AutoHashMapUnmanaged(usize, usize);
    pub const GridSize = struct { cols: usize, rows: usize };

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        /// The active pane's content changed; the caller should re-render
        /// (re-mirror) the active pane. Carries no payload.
        redraw,

        /// The active pane (or any tracked pane) emitted a terminal bell
        /// (0x07 in its %output). The caller should surface this as user
        /// attention ("needs you"). Carries no payload.
        bell,

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        switch (u_field.type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
        /// Literal key bytes from the host surface to forward to the active
        /// pane. Callers pass raw keystroke bytes; any byte value is safe.
        keys: []const u8,
        /// Clipboard paste bytes (already bracketed-paste encoded by the host
        /// surface) to forward to the active pane.
        ///
        /// Handled identically to `keys`: both are hex-encoded via
        /// `send-keys -H` so embedded newlines and binary can't split the
        /// line-based control-mode command, and both are chunked so no single
        /// command line is unbounded.
        paste: []const u8,
        /// The host surface was resized; cols/rows are the new grid size to push to tmux.
        resize: struct { cols: usize, rows: usize },
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            self.layout_arena.promote(alloc).deinit();
        }
    };

    pub const Pane = struct {
        terminal: Terminal,

        /// Bell detection state for this pane's `%output` stream. Kept
        /// per-pane and across chunks because tmux may split an escape
        /// sequence at any byte boundary.
        bell: BellScanner = .{},

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            self.terminal.deinit(alloc);
        }
    };

    /// A minimal escape-sequence scanner whose only job is to tell a real
    /// terminal bell (a bare 0x07) apart from the BEL that *terminates* a
    /// string sequence (OSC/DCS/APC/PM/SOS).
    ///
    /// tmux has no `%bell` control-mode notification, so a bell has to be
    /// detected as a raw byte in the pane output stream. Naively matching any
    /// 0x07 is wrong: shells emit `ESC ] 0 ; <title> BEL` on every prompt, so
    /// the "needs you" indicator would fire on every command.
    ///
    /// This deliberately does not implement the full VT state machine. It only
    /// tracks whether we are inside a string sequence, which is the sole case
    /// where a 0x07 is not a bell.
    pub const BellScanner = struct {
        state: ScanState = .ground,

        /// Bytes consumed so far in the current string payload, used to
        /// bound how long a malformed sequence can suppress bells.
        string_len: usize = 0,

        /// The longest string payload we will believe in. Generous, because
        /// OSC 52 clipboard payloads are genuinely large; past this we assume
        /// the introducer was spurious (or its terminator was lost) and
        /// resume treating BEL as a bell, rather than going deaf for the rest
        /// of the session. A C0 control aborts the payload long before this
        /// in practice.
        pub const STRING_MAX_BYTES = 1024 * 1024;

        const ScanState = enum {
            /// Not inside any sequence: 0x07 is a bell.
            ground,
            /// Saw ESC in ground.
            escape,
            /// Inside a string sequence payload: 0x07 is a terminator.
            string,
            /// Saw ESC inside a string sequence (possible `ESC \` ST).
            string_escape,
        };

        /// Feed a chunk of decoded pane output, advancing the state. Returns
        /// true if the chunk contained at least one real bell.
        pub fn scan(self: *BellScanner, data: []const u8) bool {
            var bell = false;
            for (data) |b| switch (self.state) {
                .ground => switch (b) {
                    0x07 => bell = true,
                    0x1b => self.state = .escape,
                    else => {},
                },

                .escape => switch (b) {
                    // The sequence introducers whose payload runs until a
                    // string terminator: OSC, DCS, APC, PM, SOS.
                    ']', 'P', '_', '^', 'X' => {
                        self.state = .string;
                        self.string_len = 0;
                    },
                    // A repeated ESC just restarts the escape.
                    0x1b => {},
                    // Anything else (CSI, charset selection, a bare ESC
                    // dispatch, ...) can't contain a string payload.
                    else => self.state = .ground,
                },

                .string => switch (b) {
                    // BEL terminates the string; it is not a bell.
                    0x07 => self.state = .ground,
                    0x1b => self.state = .string_escape,

                    // xterm aborts a string sequence on a C0 control, other
                    // than the whitespace ones that can legitimately appear
                    // in a payload (tab, newline, carriage return).
                    0x00...0x06,
                    0x08,
                    0x0b,
                    0x0c,
                    0x0e...0x1a,
                    0x1c...0x1f,
                    => self.state = .ground,

                    else => {
                        // Bound how long a malformed or misparsed introducer
                        // can keep swallowing bells.
                        self.string_len += 1;
                        if (self.string_len > STRING_MAX_BYTES) {
                            self.state = .ground;
                        }
                    },
                },

                .string_escape => switch (b) {
                    // ESC \ is the 7-bit string terminator (ST).
                    '\\' => self.state = .ground,
                    0x1b => {},
                    // A stray ESC inside the payload; stay in the string.
                    else => self.state = .string,
                },
            };
            return bell;
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(alloc: Allocator) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .tmux_version = "",
            .command_queue = command_queue,
            .windows = .empty,
            .panes = .empty,
            .pending_input = .empty,
            .pending_resize = null,
            .active_window_id = null,
            .active_pane_ids = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
            self.panes.deinit(self.alloc);
        }
        self.pending_input.deinit(self.alloc);
        self.active_pane_ids.deinit(self.alloc);
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
            // Keys and paste are both "deliver these literal bytes to the
            // active pane"; the host surface has already done any encoding
            // (including bracketed-paste framing).
            .keys, .paste => |bytes| self.nextSendKeys(bytes),
            .resize => |sz| self.nextResize(sz.cols, sz.rows),
        };
    }

    /// The maximum number of payload bytes encoded into a single
    /// `send-keys -H` command. Control mode is a line protocol and tmux reads
    /// each command line into a bounded buffer, so a large paste sent as one
    /// line risks being truncated; we split it across several commands
    /// instead. Each payload byte costs 3 characters (" XX") on the wire.
    const SEND_KEYS_CHUNK_BYTES = 2 * 1024;

    /// The most host input we will hold while waiting for a routable pane.
    /// Bounded so a session that never starts can't grow this without limit;
    /// input past the cap is dropped with a log.
    const PENDING_INPUT_MAX_BYTES = 64 * 1024;

    /// Forward literal bytes from the host surface to the active pane.
    fn nextSendKeys(self: *Viewer, bytes: []const u8) []const Action {
        if (bytes.len == 0) return &.{};
        if (self.state == .defunct) return &.{};

        // Only the command queue state can account for a command's reply
        // block, and a pane to target only exists once list-windows lands.
        // Until both hold, hold onto the bytes instead of dropping them.
        const pane_id = pane: {
            if (self.state == .command_queue) {
                if (self.activePaneId()) |id| break :pane id;
            }

            self.stashPendingInput(bytes);
            return &.{};
        };

        // Reset the action arena (same pattern as nextStartupSession) so
        // prior allocations are freed and the arena is ready for this call.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);

        const commands = sendKeysCommands(
            arena.allocator(),
            pane_id,
            bytes,
        ) catch {
            log.warn("failed to build send-keys command for pane id={}", .{pane_id});
            return &.{};
        };

        return self.queueHostCommands(commands, self.command_queue.empty());
    }

    /// Hold host input until there is a pane to route it to.
    fn stashPendingInput(self: *Viewer, bytes: []const u8) void {
        const room = PENDING_INPUT_MAX_BYTES -| self.pending_input.items.len;
        const take = @min(room, bytes.len);
        if (take < bytes.len) log.warn(
            "pending host input buffer full, dropping {d} bytes",
            .{bytes.len - take},
        );
        if (take == 0) return;

        self.pending_input.appendSlice(
            self.alloc,
            bytes[0..take],
        ) catch log.warn(
            "failed to buffer host input, dropping {d} bytes",
            .{take},
        );
    }

    /// Deliver any host input that arrived before we had a pane.
    ///
    /// Called from inside `nextCommand`'s block handling, so it never writes:
    /// the emitter at the end of `nextCommand` sends the queue head once the
    /// in-flight block is accounted for, whether or not `syncLayouts` queued
    /// anything of its own.
    fn flushPendingInput(self: *Viewer) void {
        if (self.pending_input.items.len == 0) return;
        const pane_id = self.activePaneId() orelse return;

        // A scratch arena: the action arena belongs to the caller that is
        // accumulating actions right now, and queueHostCommands copies
        // everything it keeps.
        var arena: ArenaAllocator = .init(self.alloc);
        defer arena.deinit();

        defer self.pending_input.clearRetainingCapacity();
        const commands = sendKeysCommands(
            arena.allocator(),
            pane_id,
            self.pending_input.items,
        ) catch {
            log.warn("failed to build send-keys for pending input, dropping it", .{});
            return;
        };

        _ = self.queueHostCommands(commands, false);
    }

    /// Queue host-originated commands (keystrokes, pastes, resizes) and
    /// return the actions to write right now.
    ///
    /// These must not be written out-of-band. tmux answers every command with
    /// a `%begin`/`%end` block, and `receivedCommandOutput` attributes the
    /// next block to `command_queue.first()`. An unqueued write therefore
    /// makes tmux's reply to *our* command consume the queue entry of a
    /// command that is still in flight: a resize during startup would eat the
    /// `list-windows` entry, and refresh-client's empty reply would be parsed
    /// as the window list, leaving zero windows and a blank mirror.
    ///
    /// So each command is appended as a `.user` entry, which is a no-op when
    /// its block completes and frees itself. It is written now only if it
    /// landed at the head of a previously-empty queue; otherwise the emitter
    /// at the end of `nextCommand` sends it once the in-flight block
    /// finishes, preserving order.
    ///
    /// `commands` are borrowed (arena-backed); owned copies are made.
    /// `send_now` must be false unless the caller is the one that will write
    /// the returned action; pass `command_queue.empty()` from the input
    /// paths, and false from anywhere inside `nextCommand`'s block handling,
    /// where the emitter at the end of that function owns the write.
    fn queueHostCommands(
        self: *Viewer,
        commands: []const []const u8,
        send_now: bool,
    ) []const Action {
        assert(self.state == .command_queue);
        assert(commands.len > 0);

        // A non-empty queue already has its head in flight (see the
        // `command_queue` state docs), so we must not write anything now.
        assert(!send_now or self.command_queue.empty());

        // Copy every command and reserve the queue space up front so a
        // failure part-way leaves the queue exactly as it was. Delivering a
        // truncated prefix is worse than delivering nothing: half a paste
        // lands in the shell, and a partial key sequence can be harmful.
        var owned: std.ArrayList([]const u8) = .empty;
        defer owned.deinit(self.alloc);
        const reserved = reserved: {
            owned.ensureTotalCapacityPrecise(
                self.alloc,
                commands.len,
            ) catch break :reserved false;
            for (commands) |cmd| {
                const copy = self.alloc.dupe(u8, cmd) catch break :reserved false;
                owned.appendAssumeCapacity(copy);
            }
            self.command_queue.ensureUnusedCapacity(
                self.alloc,
                commands.len,
            ) catch break :reserved false;
            break :reserved true;
        };

        if (!reserved) {
            log.warn(
                "failed to queue {d} tmux command(s), dropping them",
                .{commands.len},
            );
            for (owned.items) |cmd| self.alloc.free(cmd);
            return &.{};
        }

        // No failures past this point.
        for (owned.items) |cmd| {
            self.command_queue.appendAssumeCapacity(.{ .user = cmd });
        }

        if (!send_now) return &.{};
        const first = self.command_queue.first() orelse return &.{};
        return self.singleAction(.{ .command = first.user });
    }

    /// Build the `send-keys` commands that deliver `bytes` to `pane_id`.
    ///
    /// The payload is always hex-encoded via `-H` rather than sent literally
    /// with `-l`: control mode is line-based, so a 0x0A or 0x0D anywhere in
    /// the payload would terminate the command early and inject the remainder
    /// as a new tmux command. That is not just a paste concern — Ctrl+J
    /// encodes to 0x0A and Ctrl+M to 0x0D.
    ///
    /// The payload is chunked so no single command line is unbounded.
    fn sendKeysCommands(
        arena_alloc: Allocator,
        pane_id: usize,
        bytes: []const u8,
    ) Allocator.Error![]const []const u8 {
        assert(bytes.len > 0);
        const chunks = std.math.divCeil(
            usize,
            bytes.len,
            SEND_KEYS_CHUNK_BYTES,
        ) catch unreachable;

        const commands = try arena_alloc.alloc([]const u8, chunks);
        for (commands, 0..) |*command, i| {
            const start = i * SEND_KEYS_CHUNK_BYTES;
            const end = @min(start + SEND_KEYS_CHUNK_BYTES, bytes.len);
            command.* = try sendKeysCommand(
                arena_alloc,
                pane_id,
                bytes[start..end],
            );
        }

        return commands;
    }

    /// A single newline-terminated `send-keys -H` command for one chunk.
    fn sendKeysCommand(
        arena_alloc: Allocator,
        pane_id: usize,
        chunk: []const u8,
    ) Allocator.Error![]const u8 {
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        // The only failure mode of an Allocating writer is allocation.
        builder.writer.print(
            "send-keys -t %{d} -H",
            .{pane_id},
        ) catch return error.OutOfMemory;
        for (chunk) |b| builder.writer.print(
            " {x:0>2}",
            .{b},
        ) catch return error.OutOfMemory;
        builder.writer.writeByte('\n') catch return error.OutOfMemory;
        return builder.writer.buffered();
    }

    /// Push the host grid size to tmux.
    ///
    /// The size is never dropped just because no window is known yet: the
    /// very first resize arrives during startup, and dropping it left tmux
    /// sizing the session to the default 80x24 until the user happened to
    /// resize again. Before the command queue exists there is nowhere to
    /// account for the reply block, so we stash the size and
    /// `enterCommandQueue` flushes it.
    fn nextResize(self: *Viewer, cols: usize, rows: usize) []const Action {
        if (self.state == .defunct) return &.{};

        if (self.state != .command_queue) {
            self.pending_resize = .{ .cols = cols, .rows = rows };
            return &.{};
        }

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);

        const cmd = resizeCommand(arena.allocator(), .{
            .cols = cols,
            .rows = rows,
        }) catch return &.{};
        return self.queueHostCommands(&.{cmd}, self.command_queue.empty());
    }

    /// The tmux command that sets this control-mode client's size.
    fn resizeCommand(
        alloc: Allocator,
        sz: GridSize,
    ) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(
            alloc,
            "refresh-client -C {d}x{d}\n",
            .{ sz.cols, sz.rows },
        );
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => return self.defunct(),

            // Any begin and end (even error) is fine! Now we wait for
            // session-changed to get the initial session ID. session-changed
            // is guaranteed to come after the initial command output
            // since if the initial command is `attach` tmux will run that,
            // queue the notification, then do notificatins.
            .block_end, .block_err => {
                self.state = .startup_session;
                return &.{};
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => return self.defunct(),

            .session_changed => |info| {
                self.session_id = info.id;

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);

                return self.enterCommandQueue(
                    arena.allocator(),
                    &.{ .tmux_version, .list_windows },
                ) catch {
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };
            },

            else => return &.{},
        }
    }

    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .idle);

        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // Track whether the in-flight command slot is available. Starts true
        // if queue is empty (no command in flight). Set to true when a command
        // completes (block_end/block_err) or the queue is reset (session_changed).
        var command_consumed = self.command_queue.empty();

        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),

            inline .block_end,
            .block_err,
            => |content, tag| {
                self.receivedCommandOutput(
                    &actions,
                    content,
                    tag == .block_err,
                ) catch {
                    log.warn("failed to process command output, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed since a block end/err is the output
                // from a command.
                command_consumed = true;
            },

            .output => |out| if (self.receivedOutput(
                out.pane_id,
                out.data,
            )) |result| {
                // The pane's content changed; signal the caller to
                // re-mirror the active pane so the cell reflects the
                // new output. Uses the same arena-backed actions list
                // and append pattern as the `.windows` action.
                if (result.changed) {
                    self.appendRedraw(&actions);
                    if (result.bell) {
                        var arena = self.action_arena.promote(self.alloc);
                        defer self.action_arena = arena.state;
                        actions.append(arena.allocator(), .bell) catch {
                            log.warn("failed to queue bell action for pane output", .{});
                        };
                    }
                }
            } else |err| {
                log.warn(
                    "failed to process output for pane id={}: {}",
                    .{ out.pane_id, err },
                );
            },

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed because sessionChanged resets
                // our entire viewer.
                command_consumed = true;
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // The active pane of a window changed. Track it so input and
            // mirroring follow tmux's focus, and redraw in case it was the
            // window we're currently showing.
            .window_pane_changed => |info| {
                self.active_pane_ids.put(
                    self.alloc,
                    info.window_id,
                    info.pane_id,
                ) catch {
                    log.warn(
                        "failed to track active pane window={} pane={}",
                        .{ info.window_id, info.pane_id },
                    );
                };

                // Only the window we're actually showing changes what the
                // mirror renders; a background window's pane switch doesn't.
                if (self.activeWindow()) |window| {
                    if (window.id == info.window_id) self.appendRedraw(&actions);
                }
            },

            // The session's active window changed. Only our own session
            // matters; other clients' sessions are none of our business.
            .session_window_changed => |info| if (info.session_id == self.session_id) {
                self.active_window_id = info.window_id;
                self.appendRedraw(&actions);
            },

            // We ignore this one. It means a session was created or
            // destroyed. If it was our own session we will get an exit
            // notification very soon. If it is another session we don't
            // care.
            .sessions_changed => {},

            // We don't use window names for anything, currently.
            .window_renamed => {},

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => {},
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands. We only emit a
        // command if a prior command was consumed (or never existed).
        if (self.state == .command_queue and command_consumed) {
            if (self.command_queue.first()) |next_command| {
                // We should not have any commands, because our nextCommand
                // always queues them.
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();

                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
            }
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        // Clear our prior window arena and setup our layout
        window.layout = layout: {
            var arena = window.layout_arena.promote(self.alloc);
            defer window.layout_arena = arena.state;
            _ = arena.reset(.retain_capacity);
            break :layout Layout.parseWithChecksum(
                arena.allocator(),
                layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return err;
            };
        };

        // Reset our arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
    }

    /// When a window is added to the session, we need to refresh our window
    /// list to get the new window's information.
    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id; // We refresh all windows via list-windows

        // Queue list-windows to get the updated window list
        try self.queueCommands(&.{.list_windows});
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.deinit(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.alloc,
            &self.panes,
            &panes,
            window.layout,
        );

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Get our list of added panes and setup our command queue
        // to populate them.
        // TODO: errdefer cleanup
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added = true;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });
            }

            // If we added any panes, then we also want to resync the pane
            // state (terminal modes and cursor positions and so on).
            if (added) try self.queueCommands(&.{.pane_state});
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Drop active-pane tracking for windows that no longer exist so the
        // map can't grow without bound over a long session. Purely hygiene:
        // `activePaneId` already validates entries, and we're past the point
        // where we can fail, so an allocation failure just skips the prune.
        prune: {
            var stale: std.ArrayList(usize) = .empty;
            defer stale.deinit(self.alloc);

            var it = self.active_pane_ids.iterator();
            while (it.next()) |entry| {
                const window_id = entry.key_ptr.*;
                const known = for (self.windows.items) |window| {
                    if (window.id == window_id) break true;
                } else false;
                if (!known) stale.append(self.alloc, window_id) catch break :prune;
            }

            for (stale.items) |window_id| {
                _ = self.active_pane_ids.remove(window_id);
            }
        }

        // Likewise for an active window that was closed; activeWindow falls
        // back to the first window until tmux tells us the new one.
        if (self.active_window_id) |id| {
            const known = for (self.windows.items) |window| {
                if (window.id == id) break true;
            } else false;
            if (!known) self.active_window_id = null;
        }

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                var entry = entry_const;
                entry.value.deinit(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        var replacement: Viewer = try .init(self.alloc);
        errdefer replacement.deinit();

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Setup our command queue and put ourselves in the command queue
        // state.
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and jump directly to the list
        self.session_id = session_id;

        assert(self.state == .command_queue);
    }

    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return;
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            .user => {},

            .pane_state => {
                try self.receivedPaneState(content);

                // pane_state is the final capture command for a pane, so by
                // now the captured content is fully in and the active screen
                // has been restored to the pane's real mode. Signal a redraw
                // so the first frame is mirrored from real content rather
                // than the empty pane the initial `.windows` action saw.
                try actions.append(arena_alloc, .redraw);
            },

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
            ),

            .pane_visible => |cap| {
                try self.receivedPaneVisible(
                    cap.screen_key,
                    cap.id,
                    content,
                );

                // The pane now has visible content captured; signal a redraw
                // so the cell re-mirrors with real content.
                try actions.append(arena_alloc, .redraw);
            },

            .tmux_version => try self.receivedTmuxVersion(content),
        }
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch |err| {
            log.info("failed to parse tmux version: {s}", .{line});
            return err;
        };

        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // If there is an error, reset our actions to what it was before.
        errdefer actions.shrinkRetainingCapacity(actions.items.len);

        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        defer windows.deinit(self.alloc);

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch |err| {
                log.info("failed to parse list-windows line: {s}", .{line});
                return err;
            };

            // Parse the layout
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const window_alloc = arena.allocator();
            const layout: Layout = Layout.parseWithChecksum(
                window_alloc,
                data.window_layout,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                return err;
            };

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout_arena = arena.state,
                .layout = layout,
            });
        }

        // Setup our windows action so the caller can process GUI
        // window changes.
        try actions.append(arena_alloc, .{ .windows = windows.items });

        // Sync up our layouts. This will populate unknown panes, prune, etc.
        try self.syncLayouts(windows.items);

        // We finally have a pane to target, so deliver anything the host
        // typed or pasted while the session was still starting up.
        self.flushPendingInput();
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse list-panes line: {s}", .{line});
                return err;
            };

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr;
            const t: *Terminal = &pane.terminal;

            // Determine which screen to use based on alternate_on
            const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

            // Set cursor position on the appropriate screen (tmux uses 0-based)
            if (t.screens.get(screen_key)) |screen| {
                cursor: {
                    const cursor_x = std.math.cast(
                        size.CellCountInt,
                        data.cursor_x,
                    ) orelse break :cursor;
                    const cursor_y = std.math.cast(
                        size.CellCountInt,
                        data.cursor_y,
                    ) orelse break :cursor;
                    if (cursor_x >= screen.pages.cols or
                        cursor_y >= screen.pages.rows) break :cursor;
                    screen.cursorAbsolute(cursor_x, cursor_y);
                }

                // Set cursor shape on this screen
                if (data.cursor_shape.len > 0) {
                    if (std.mem.eql(u8, data.cursor_shape, "block")) {
                        screen.cursor.cursor_style = .block;
                    } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                        screen.cursor.cursor_style = .underline;
                    } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                        screen.cursor.cursor_style = .bar;
                    }
                }
                // "default" or unknown: leave as-is
            }

            // Set alternate screen saved cursor position
            if (t.screens.get(.alternate)) |alt_screen| cursor: {
                const alt_x = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_x,
                ) orelse break :cursor;
                const alt_y = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_y,
                ) orelse break :cursor;

                // If our coordinates are outside our screen we ignore it.
                // tmux actually sends MAX_INT for when there isn't a set
                // cursor position, so this isn't theoretical.
                if (alt_x >= alt_screen.pages.cols or
                    alt_y >= alt_screen.pages.rows) break :cursor;

                alt_screen.cursorAbsolute(alt_x, alt_y);
            }

            // Set cursor visibility
            t.modes.set(.cursor_visible, data.cursor_flag);

            // Set cursor blinking
            t.modes.set(.cursor_blinking, data.cursor_blinking);

            // Terminal modes
            t.modes.set(.insert, data.insert_flag);
            t.modes.set(.wraparound, data.wrap_flag);
            t.modes.set(.keypad_keys, data.keypad_flag);
            t.modes.set(.cursor_keys, data.keypad_cursor_flag);
            t.modes.set(.origin, data.origin_flag);

            // Mouse modes
            t.modes.set(.mouse_event_any, data.mouse_all_flag);
            t.modes.set(.mouse_event_button, data.mouse_any_flag);
            t.modes.set(.mouse_event_normal, data.mouse_button_flag);
            t.modes.set(.mouse_event_x10, data.mouse_standard_flag);
            t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
            t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);

            // Focus and bracketed paste
            t.modes.set(.focus_event, data.focus_flag);
            t.modes.set(.bracketed_paste, data.bracketed_paste);

            // Scroll region (tmux uses 0-based values)
            scroll: {
                const scroll_top = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_upper,
                ) orelse break :scroll;
                const scroll_bottom = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_lower,
                ) orelse break :scroll;
                t.scrolling_region.top = scroll_top;
                t.scrolling_region.bottom = scroll_bottom;
            }

            // Tab stops - parse comma-separated list and set
            t.tabstops.reset(0); // Clear all tabstops first
            if (data.pane_tabs.len > 0) {
                var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
                while (tabs_it.next()) |tab_str| {
                    const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                    const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                    if (col_cell >= t.cols) continue;
                    t.tabstops.set(col_cell);
                }
            }

            // Restore the pane terminal's active screen to its real mode.
            // The capture-pane replay (pane_history/pane_visible) ends on the
            // alternate screen because each handler calls switchScreen, so
            // without this the active screen would be the empty alternate and
            // mirrorActivePane would clone an empty screen. Subsequent
            // %output applies to whatever screen the app's own alt-screen
            // toggles select, keeping this correct over time.
            _ = try t.switchScreen(screen_key);
        }
    }

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        const screen: *Screen = t.screens.active;

        // Get a VT stream from the terminal so we can send data as-is into
        // it. This will populate the active area too so it won't be exactly
        // correct but we'll get the active contents soon.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);

        // Populate the active area to be empty since this is only history.
        // We'll fill it with blanks and move the cursor to the top-left.
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);

        // Erase the active area and reset the cursor to the top-left
        // before writing the visible content.
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
    }

    /// The result of applying a chunk of `%output` to a pane.
    const OutputResult = struct {
        /// The bytes were applied to a tracked pane, so its content changed
        /// and the caller should re-mirror.
        changed: bool = false,

        /// The chunk contained at least one real terminal bell.
        bell: bool = false,
    };

    /// Apply live %output bytes to the pane terminal's active screen.
    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !OutputResult {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return .{};
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;

        // Scan for bells before feeding the stream; the scanner keeps its
        // state on the pane so sequences split across chunks still parse.
        const bell = pane.bell.scan(data);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(data);
        return .{ .changed = true, .bell = bell };
    }

    fn initLayout(
        gpa_alloc: Allocator,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // If we already have this pane, it is already initialized
                // so just copy it over.
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;
                    break :pane;
                }

                // TODO: We need to gracefully handle overflow of our
                // max cols/width here. In practice we shouldn't hit this
                // so we cast but its not safe.
                var t: Terminal = try .init(gpa_alloc, .{
                    .cols = @intCast(layout.width),
                    .rows = @intCast(layout.height),
                });
                errdefer t.deinit(gpa_alloc);

                gop.value_ptr.* = .{
                    .terminal = t,
                };
            },
        }
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our commands
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| self.command_queue.appendAssumeCapacity(cmd);

        // A host resize arrived before we had a queue to account for its
        // reply block. Send it behind the startup commands now that we do.
        if (self.pending_resize) |sz| {
            const cmd = try resizeCommand(self.alloc, sz);
            errdefer self.alloc.free(cmd);
            try self.command_queue.ensureUnusedCapacity(self.alloc, 1);
            self.command_queue.appendAssumeCapacity(.{ .user = cmd });
            self.pending_resize = null;
        }

        // Move into the command queue state
        self.state = .command_queue;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Append a `.redraw` action using the action arena, logging and
    /// dropping it if the arena can't grow. A dropped redraw only costs a
    /// stale frame until the next output, so it is never fatal.
    fn appendRedraw(self: *Viewer, actions: *std.ArrayList(Action)) void {
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        actions.append(arena.allocator(), .redraw) catch {
            log.warn("failed to queue redraw action", .{});
        };
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;
        return self.singleAction(.exit);
    }

    /// Returns the Terminal of the active pane, or null if no pane is
    /// available yet.
    pub fn activePaneTerminal(self: *Viewer) ?*Terminal {
        const pane_id = self.activePaneId() orelse return null;
        const entry = self.panes.getEntry(pane_id) orelse return null;
        return &entry.value_ptr.terminal;
    }

    /// The ID of the pane that host input is routed to and that the mirror
    /// renders: the active pane of the active window.
    ///
    /// tmux reports the active window via `%session-window-changed` and a
    /// window's active pane via `%window-pane-changed`. Either may not have
    /// arrived yet, or may name something we no longer track, so both degrade
    /// to "the first one in order" — which is exact for the common
    /// single-window/single-pane case.
    ///
    /// This is the single source of truth for "which pane"; every caller
    /// (input, paste, mirroring) must go through it or they will disagree
    /// after a window or pane switch.
    pub fn activePaneId(self: *const Viewer) ?usize {
        const window = self.activeWindow() orelse return null;
        if (self.active_pane_ids.get(window.id)) |id| {
            // The reported pane must still exist in this window's layout;
            // a layout change can retire it before we hear about a new one.
            if (self.panes.contains(id) and
                layoutHasPane(window.layout, id)) return id;
        }

        return firstPaneId(window.layout);
    }

    /// The active window, falling back to the first window we know about.
    fn activeWindow(self: *const Viewer) ?*const Window {
        if (self.windows.items.len == 0) return null;
        if (self.active_window_id) |id| {
            for (self.windows.items) |*window| {
                if (window.id == id) return window;
            }
        }

        return &self.windows.items[0];
    }

    /// Depth-first search for whether a layout tree contains a pane id.
    fn layoutHasPane(node: Layout, id: usize) bool {
        return switch (node.content) {
            .pane => |pane_id| pane_id == id,
            .horizontal, .vertical => |children| for (children) |child| {
                if (layoutHasPane(child, id)) break true;
            } else false,
        };
    }

    /// Depth-first walk of a layout tree returning the first pane leaf's id.
    fn firstPaneId(node: Layout) ?usize {
        return switch (node.content) {
            .pane => |id| id,
            .horizontal => |children| for (children) |child| {
                if (firstPaneId(child)) |id| return id;
            } else null,
            .vertical => |children| for (children) |child| {
                if (firstPaneId(child)) |id| return id;
            } else null,
        };
    }

    /// Test helper: the `.user` (host-originated) commands currently sitting
    /// in the command queue, in order. Caller owns the returned slice.
    fn testUserCommands(
        self: *Viewer,
        alloc: Allocator,
    ) Allocator.Error![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(alloc);
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |cmd| switch (cmd.*) {
            .user => |v| try list.append(alloc, v),
            else => {},
        };
        return list.toOwnedSlice(alloc);
    }

    /// Test helper: drive the viewer from a fresh init through startup,
    /// list-windows, and a single pane populated with "Hello, world!".
    /// Leaves the viewer in command_queue state with one window, one pane
    /// (id 0) whose history screen contains "Hello, world!".
    ///
    /// Layout used: single 80x24 pane (id 0) in session $0 window @0.
    pub fn setupSinglePane(self: *Viewer) !void {
        try testViewer(self, &.{
            // startup_block → startup_session
            .{ .input = .{ .tmux = .{ .block_end = "" } } },
            // session_changed → queues tmux_version (display-message)
            .{
                .input = .{ .tmux = .{ .session_changed = .{
                    .id = 0,
                    .name = "main",
                } } },
            },
            // version response "3.5a" → queues list-windows
            .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
            // list-windows response: single pane layout → queues 4 capture-panes + pane_state
            .{
                .input = .{ .tmux = .{
                    .block_end = "$0 @0 80 24 b25d,80x24,0,0,0",
                } },
            },
            // pane_history primary with "Hello, world!" content
            .{ .input = .{ .tmux = .{ .block_end = "Hello, world!" } } },
            // pane_visible primary (empty)
            .{ .input = .{ .tmux = .{ .block_end = "" } } },
            // pane_history alternate (empty)
            .{ .input = .{ .tmux = .{ .block_end = "" } } },
            // pane_visible alternate (empty)
            .{ .input = .{ .tmux = .{ .block_end = "" } } },
            // pane_state for pane 0: cursor (0,0), alternate_on=0 (field 8).
            // A real (non-empty) line is required so receivedPaneState runs
            // the active-screen restore (back to primary) for the pane.
            .{ .input = .{ .tmux = .{
                .block_end = "%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;23;8,16,24,32,40,48,56,64,72",
            } } },
        });
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes.
    pane_state,

    /// Get the tmux server version.
    tmux_version,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            => {},
            .user => |v| alloc.free(v),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S - = start at the top of history ("-")
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -t %{d} = target a specific pane ID
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -F '{s}'\n",
                .{comptime Format.list_panes.comptimeFormat()},
            )),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            .user => |v| try writer.writeAll(v),
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
        },
    };

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_width,
            .window_height,
            .window_layout,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .exit },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Live %output to a tracked pane emits exactly one redraw.
                    try testing.expectEqual(1, actions.len);
                    try testing.expect(actions[0] == .redraw);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4 capture-pane + 1 pane_state)
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes.
        // This should NOT return a command action since queue was not empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // Should not contain a command action
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 0 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 4 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // Active screen starts with "prompt %" at beginning
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        // capture-pane pane 4 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;42;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "tmux activePaneTerminal returns the single pane's terminal" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    const t = viewer.activePaneTerminal() orelse return error.NoActivePane;
    // After capture, receivedPaneState restores the active screen to the
    // pane's real mode (primary, since alternate_on=false), where the
    // "Hello, world!" history content lives. No manual switch needed.
    const str = try t.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(str);
    try testing.expect(std.mem.indexOf(u8, str, "Hello, world!") != null);
}

test "tmux output emits redraw action" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    const actions = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "X",
    } } });

    var found_redraw = false;
    for (actions) |a| switch (a) {
        .redraw => found_redraw = true,
        else => {},
    };
    try testing.expect(found_redraw);
}

test "tmux pane active screen restored after capture" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    // setupSinglePane's pane_state has alternate_on=false, so the restore
    // path in receivedPaneState should leave the active screen on primary.
    try viewer.setupSinglePane();

    // WITHOUT manually switching screens, the active screen must be primary
    // (where the "Hello, world!" history content lives).
    const t = viewer.activePaneTerminal() orelse return error.NoActivePane;
    const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expect(std.mem.indexOf(u8, str, "Hello, world!") != null);
}

test "tmux keys input emits send-keys command for active pane" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane(); // active pane id 0 exists

    const actions = viewer.next(.{ .keys = "ls\r" });
    var found: ?[]const u8 = null;
    for (actions) |a| switch (a) {
        .command => |c| found = c,
        else => {},
    };
    const cmd = found orelse return error.NoCommand;
    try testing.expect(std.mem.startsWith(u8, cmd, "send-keys -t %0 -H "));
    // 'l'=0x6c 's'=0x73 '\r'=0x0d
    try testing.expect(std.mem.indexOf(u8, cmd, "6c 73 0d") != null);
    try testing.expect(cmd[cmd.len - 1] == '\n');
}

test "tmux keys input hex-encodes newline-bearing keys" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // Ctrl+J is a literal 0x0A. Sent with `send-keys -l` it would terminate
    // the control-mode command line and inject "x" as a new tmux command.
    const actions = viewer.next(.{ .keys = "\nx" });
    try testing.expectEqual(@as(usize, 1), actions.len);
    const cmd = actions[0].command;
    try testing.expectEqualStrings("send-keys -t %0 -H 0a 78\n", cmd);
    // Exactly one newline: the command terminator.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, cmd, "\n"),
    );
}

test "tmux paste input emits hex send-keys command for active pane" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane(); // active pane id 0 exists

    const actions = viewer.next(.{ .paste = "hi\n" });
    var found: ?[]const u8 = null;
    for (actions) |a| switch (a) {
        .command => |c| found = c,
        else => {},
    };
    const cmd = found orelse return error.NoCommand;
    try testing.expect(std.mem.startsWith(u8, cmd, "send-keys -t %0 -H "));
    // 'h'=0x68 'i'=0x69 '\n'=0x0a — newline survives as hex, not a split.
    try testing.expect(std.mem.indexOf(u8, cmd, "68 69 0a") != null);
    try testing.expect(cmd[cmd.len - 1] == '\n');
}

test "tmux paste input with no active pane emits nothing" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    const actions = viewer.next(.{ .paste = "x" });
    try testing.expectEqual(@as(usize, 0), actions.len);
}

test "tmux keys input with no active pane emits nothing" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    const actions = viewer.next(.{ .keys = "x" });
    try testing.expectEqual(@as(usize, 0), actions.len);
}

test "tmux resize input emits refresh-client size command" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

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

test "tmux resize during startup is stashed and flushed onto the queue" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    // Before the command queue exists there is nowhere to account for the
    // reply block, so the size is stashed rather than written out-of-band
    // (which would desync the queue) and rather than dropped (which left
    // tmux stuck at its default 80x24).
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .resize = .{
        .cols = 100,
        .rows = 30,
    } }).len);
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .resize = .{
        .cols = 120,
        .rows = 40,
    } }).len);
    // Only the newest size matters.
    try testing.expectEqual(@as(usize, 120), viewer.pending_resize.?.cols);

    // Entering the command queue flushes it behind the startup commands.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 0,
        .name = "main",
    } } });
    try testing.expect(viewer.pending_resize == null);

    const queued = try viewer.testUserCommands(alloc);
    defer alloc.free(queued);
    try testing.expectEqual(@as(usize, 1), queued.len);
    try testing.expectEqualStrings("refresh-client -C 120x40\n", queued[0]);
}

test "tmux resize during startup does not steal the list-windows reply" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 0,
        .name = "main",
    } } });

    // A resize lands while [tmux_version, list_windows] are queued. Written
    // out-of-band, refresh-client's empty reply would be consumed as the
    // list-windows output and we would end up with zero windows.
    _ = viewer.next(.{ .resize = .{ .cols = 120, .rows = 40 } });

    _ = viewer.next(.{ .tmux = .{ .block_end = "3.5a" } });
    _ = viewer.next(.{ .tmux = .{
        .block_end = "$0 @0 80 24 b25d,80x24,0,0,0",
    } });

    // The window list parsed correctly.
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());

    // And the resize is still queued to go out.
    const queued = try viewer.testUserCommands(alloc);
    defer alloc.free(queued);
    try testing.expectEqual(@as(usize, 1), queued.len);
    try testing.expectEqualStrings("refresh-client -C 120x40\n", queued[0]);
}

test "tmux resize on an idle queue is written immediately" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();
    try testing.expect(viewer.command_queue.empty());

    const actions = viewer.next(.{ .resize = .{ .cols = 120, .rows = 40 } });
    try testing.expectEqual(@as(usize, 1), actions.len);
    try testing.expectEqualStrings(
        "refresh-client -C 120x40\n",
        actions[0].command,
    );
}

test "tmux keys sent while a command is in flight go out afterwards" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 0,
        .name = "main",
    } } });
    _ = viewer.next(.{ .tmux = .{ .block_end = "3.5a" } });
    _ = viewer.next(.{ .tmux = .{
        .block_end = "$0 @0 80 24 b25d,80x24,0,0,0",
    } });

    // capture-pane commands are in flight; typing must not write now.
    try testing.expect(!viewer.command_queue.empty());
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .keys = "x" }).len);
    {
        const queued = try viewer.testUserCommands(alloc);
        defer alloc.free(queued);
        try testing.expectEqual(@as(usize, 1), queued.len);
        try testing.expectEqualStrings("send-keys -t %0 -H 78\n", queued[0]);
    }

    // Drain the four capture-panes and the pane_state. The keystroke is last
    // in the queue, so it is emitted once pane_state's block completes and
    // its own reply block is then consumed by the `.user` entry.
    for (0..4) |_| _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    const actions = viewer.next(.{ .tmux = .{
        .block_end = "%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;23;8,16,24,32,40,48,56,64,72",
    } });
    var found: ?[]const u8 = null;
    for (actions) |a| switch (a) {
        .command => |c| found = c,
        else => {},
    };
    try testing.expectEqualStrings("send-keys -t %0 -H 78\n", found orelse return error.NoCommand);

    // Its reply block is absorbed by the `.user` entry, leaving an empty,
    // in-sync queue.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expect(viewer.command_queue.empty());
}

test "tmux paste chunks large payloads into bounded commands" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // 3 chunks worth: one unbounded send-keys line risks truncation in tmux.
    const payload = try alloc.alloc(u8, Viewer.SEND_KEYS_CHUNK_BYTES * 2 + 1);
    defer alloc.free(payload);
    @memset(payload, 'a');

    // The queue is idle, so the first chunk goes out now and the rest wait
    // their turn behind it.
    const actions = viewer.next(.{ .paste = payload });
    try testing.expectEqual(@as(usize, 1), actions.len);

    const queued = try viewer.testUserCommands(alloc);
    defer alloc.free(queued);
    try testing.expectEqual(@as(usize, 3), queued.len);
    try testing.expectEqualStrings(queued[0], actions[0].command);

    var encoded: usize = 0;
    for (queued) |cmd| {
        try testing.expect(std.mem.startsWith(u8, cmd, "send-keys -t %0 -H "));
        try testing.expect(cmd[cmd.len - 1] == '\n');
        encoded += std.mem.count(u8, cmd, " 61");
    }

    // Every source byte is delivered exactly once, in order.
    try testing.expectEqual(payload.len, encoded);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, queued[2], " 61"));
}

test "tmux input follows the active window and pane" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // Baseline: the only window/pane.
    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());

    // tmux reports a different active pane in our window.
    _ = viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 99,
    } } });
    // Pane 99 isn't in this window's layout, so we stay on the real pane
    // rather than routing input into nowhere.
    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());

    // An unknown active window also falls back to the first window.
    _ = viewer.next(.{ .tmux = .{ .session_window_changed = .{
        .session_id = 0,
        .window_id = 1234,
    } } });
    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());
}

test "tmux BellScanner bare BEL is a bell" {
    var s: Viewer.BellScanner = .{};
    try testing.expect(s.scan("hello\x07world"));
}

test "tmux BellScanner OSC terminator is not a bell" {
    // The shell prompt sequence: every command emits one of these.
    var s: Viewer.BellScanner = .{};
    try testing.expect(!s.scan("\x1b]0;user@host: ~\x07$ "));
}

test "tmux BellScanner OSC split across chunks is not a bell" {
    var s: Viewer.BellScanner = .{};
    try testing.expect(!s.scan("\x1b]0;user@host"));
    // The BEL arrives in a later chunk; the scanner must still know it is
    // inside the OSC payload.
    try testing.expect(!s.scan(": ~\x07$ "));
}

test "tmux BellScanner BEL after the OSC ends is a bell" {
    var s: Viewer.BellScanner = .{};
    try testing.expect(!s.scan("\x1b]0;title\x07"));
    try testing.expect(s.scan("\x07"));
}

test "tmux BellScanner ST-terminated string then BEL is a bell" {
    var s: Viewer.BellScanner = .{};
    try testing.expect(!s.scan("\x1b]8;;https://example.com\x1b\\"));
    try testing.expect(s.scan("link\x07"));
}

test "tmux BellScanner other string sequences swallow BEL" {
    inline for (.{ "P", "_", "^", "X" }) |intro| {
        var s: Viewer.BellScanner = .{};
        try testing.expect(!s.scan("\x1b" ++ intro ++ "payload\x07"));
        try testing.expect(s.scan("\x07"));
    }
}

test "tmux BellScanner CSI does not start a string" {
    var s: Viewer.BellScanner = .{};
    try testing.expect(s.scan("\x1b[1;31mred\x07"));
}

test "tmux output with OSC title emits no bell action" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    const actions = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "\x1b]0;zsh\x07$ ",
    } } });
    for (actions) |a| try testing.expect(a != .bell);
}

test "tmux output with a real bell emits a bell action" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    const actions = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "done\x07",
    } } });
    var found = false;
    for (actions) |a| if (a == .bell) {
        found = true;
    };
    try testing.expect(found);
}

test "tmux bell state persists across output chunks" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    try viewer.setupSinglePane();

    // tmux may split an OSC anywhere; the BEL terminator arriving in a later
    // %output must still not be treated as a bell.
    for (viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "\x1b]0;my-title",
    } } })) |a| try testing.expect(a != .bell);
    for (viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "-continued\x07",
    } } })) |a| try testing.expect(a != .bell);
}

test "tmux input follows a window switch" {
    var viewer: Viewer = try .init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 0,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        // Two windows, one pane each.
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 80 24 b25d,80x24,0,0,0
            \\$0 @1 80 24 b25e,80x24,0,0,1
            ,
        } } },
    });

    try testing.expectEqual(@as(usize, 2), viewer.windows.items.len);

    // Before tmux tells us otherwise, the first window's first pane.
    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());

    // tmux switches the session's active window; input must follow.
    _ = viewer.next(.{ .tmux = .{ .session_window_changed = .{
        .session_id = 0,
        .window_id = 1,
    } } });
    try testing.expectEqual(@as(?usize, 1), viewer.activePaneId());

    // capture-panes are still in flight, so the keystroke is queued behind
    // them rather than written out-of-band.
    _ = viewer.next(.{ .keys = "x" });
    {
        const queued = try viewer.testUserCommands(testing.allocator);
        defer testing.allocator.free(queued);
        try testing.expectEqual(@as(usize, 1), queued.len);
        try testing.expectEqualStrings("send-keys -t %1 -H 78\n", queued[0]);
    }

    // Another session's window switch is not ours to follow.
    _ = viewer.next(.{ .tmux = .{ .session_window_changed = .{
        .session_id = 7,
        .window_id = 0,
    } } });
    try testing.expectEqual(@as(?usize, 1), viewer.activePaneId());
}

test "tmux input follows a pane switch within a window" {
    var viewer: Viewer = try .init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 0,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        // One window split into panes 0 and 1.
        .{ .input = .{ .tmux = .{
            .block_end = "$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]",
        } } },
    });

    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());

    _ = viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 1,
    } } });
    try testing.expectEqual(@as(?usize, 1), viewer.activePaneId());

    _ = viewer.next(.{ .paste = "y" });
    const queued = try viewer.testUserCommands(testing.allocator);
    defer testing.allocator.free(queued);
    try testing.expectEqual(@as(usize, 1), queued.len);
    try testing.expectEqualStrings("send-keys -t %1 -H 79\n", queued[0]);
}

test "tmux BellScanner recovers from an unterminated string sequence" {
    var s: Viewer.BellScanner = .{};

    // A stray OSC introducer with no terminator must not deafen us forever.
    try testing.expect(!s.scan("\x1b]0;"));

    // Fed in chunks, as tmux would: the cap is on the payload, not a chunk.
    const chunk = "x" ** 4096;
    for (0..Viewer.BellScanner.STRING_MAX_BYTES / chunk.len + 1) |_| {
        try testing.expect(!s.scan(chunk));
    }

    // Past the cap we're back to treating BEL as a real bell.
    try testing.expect(s.scan("\x07"));
}

test "tmux BellScanner a C0 control aborts a string sequence" {
    var s: Viewer.BellScanner = .{};

    // xterm aborts a string on a C0 control other than tab/newline/CR.
    try testing.expect(!s.scan("\x1b]0;title\x18"));
    try testing.expect(s.scan("\x07"));

    // ...but whitespace is legal inside a payload.
    var t: Viewer.BellScanner = .{};
    try testing.expect(!t.scan("\x1b]0;a\tb\r\nc\x07"));
}

test "tmux background window pane switch does not redraw" {
    var viewer: Viewer = try .init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 0,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 80 24 b25d,80x24,0,0,0
            \\$0 @1 80 24 b25e,80x24,0,0,1
            ,
        } } },
    });

    // Window @1 is not the one we're showing, so its pane switch changes
    // nothing on screen.
    for (viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 1,
        .pane_id = 1,
    } } })) |a| try testing.expect(a != .redraw);

    // The window we are showing does.
    var found = false;
    for (viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 0,
    } } })) |a| {
        if (a == .redraw) found = true;
    }
    try testing.expect(found);
}

test "tmux active pane tracking is pruned when a window closes" {
    var viewer: Viewer = try .init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 0,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 80 24 b25d,80x24,0,0,0
            \\$0 @1 80 24 b25e,80x24,0,0,1
            ,
        } } },
    });

    _ = viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 1,
        .pane_id = 1,
    } } });
    _ = viewer.next(.{ .tmux = .{ .session_window_changed = .{
        .session_id = 0,
        .window_id = 1,
    } } });
    try testing.expectEqual(@as(u32, 1), viewer.active_pane_ids.count());
    try testing.expectEqual(@as(?usize, 1), viewer.active_window_id);

    // Drain the capture-pane/pane_state commands queued for both panes so
    // the next block_end is unambiguously the list-windows reply.
    while (!viewer.command_queue.empty()) {
        _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    }

    // Window @1 closes: a window change re-lists, and only @0 comes back.
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 2 } } });
    _ = viewer.next(.{ .tmux = .{
        .block_end = "$0 @0 80 24 b25d,80x24,0,0,0",
    } });

    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
    try testing.expectEqual(@as(u32, 0), viewer.active_pane_ids.count());
    try testing.expectEqual(@as(?usize, null), viewer.active_window_id);
    try testing.expectEqual(@as(?usize, 0), viewer.activePaneId());
}

test "tmux paste before startup completes is delivered once a pane exists" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    // Typed/pasted into an agent cell that is still attaching: there is no
    // pane to target yet, so it must be held rather than dropped.
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .paste = "hi" }).len);
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .keys = "!" }).len);
    try testing.expectEqualStrings("hi!", viewer.pending_input.items);

    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 0,
        .name = "main",
    } } });
    _ = viewer.next(.{ .tmux = .{ .block_end = "3.5a" } });
    _ = viewer.next(.{ .tmux = .{
        .block_end = "$0 @0 80 24 b25d,80x24,0,0,0",
    } });

    // Queued behind the capture-pane commands, in one send-keys, in order.
    try testing.expectEqual(@as(usize, 0), viewer.pending_input.items.len);
    const queued = try viewer.testUserCommands(alloc);
    defer alloc.free(queued);
    try testing.expectEqual(@as(usize, 1), queued.len);
    // 'h'=68 'i'=69 '!'=21
    try testing.expectEqualStrings("send-keys -t %0 -H 68 69 21\n", queued[0]);
}

test "tmux pending host input is bounded" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();

    const chunk = try alloc.alloc(u8, Viewer.PENDING_INPUT_MAX_BYTES);
    defer alloc.free(chunk);
    @memset(chunk, 'a');

    _ = viewer.next(.{ .paste = chunk });
    try testing.expectEqual(
        @as(usize, Viewer.PENDING_INPUT_MAX_BYTES),
        viewer.pending_input.items.len,
    );

    // A session that never starts must not grow this without limit.
    _ = viewer.next(.{ .paste = chunk });
    try testing.expectEqual(
        @as(usize, Viewer.PENDING_INPUT_MAX_BYTES),
        viewer.pending_input.items.len,
    );
}

test "tmux defunct viewer buffers nothing" {
    const alloc = testing.allocator;
    var viewer: Viewer = try .init(alloc);
    defer viewer.deinit();
    _ = viewer.next(.{ .tmux = .exit });

    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .keys = "x" }).len);
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .resize = .{
        .cols = 80,
        .rows = 24,
    } }).len);
    try testing.expectEqual(@as(usize, 0), viewer.pending_input.items.len);
    try testing.expect(viewer.pending_resize == null);
}
