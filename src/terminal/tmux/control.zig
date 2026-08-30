//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const oni = @import("oniguruma");

const log = std.log.scoped(.terminal_tmux);

/// A tmux control mode parser. This takes in output from tmux control
/// mode and parses it into a structured notifications.
///
/// It is up to the caller to establish the connection to the tmux
/// control mode session in some way (e.g. via exec, a network socket,
/// whatever). This is fully agnostic to how the data is received and sent.
pub const Parser = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress notifications, output, etc.
    buffer: std.Io.Writer.Allocating,

    /// The maximum size in bytes of the buffer. This is used to limit
    /// memory usage. If the buffer exceeds this size, the client will
    /// enter a broken state (the control mode session will be forcibly
    /// exited and future data dropped).
    max_bytes: usize = 1024 * 1024,

    const State = enum {
        /// Outside of any active notifications. This should drop any output
        /// unless it is '%' on the first byte of a line. The buffer will be
        /// cleared when it sees '%', this is so that the previous notification
        /// data is valid until we receive/process new data.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing. When this state is set,
        /// the buffer has been deinited and must not be accessed.
        broken,

        /// Inside an active notification (started with '%').
        notification,

        /// Inside a begin/end block.
        block,
    };

    pub fn deinit(self: *Parser) void {
        // If we're in a broken state, we already deinited
        // the buffer, so we don't need to do anything.
        if (self.state == .broken) return;

        self.buffer.deinit();
    }

    // Handle a byte of input.
    //
    // If we reach our byte limit this will return OutOfMemory. It only
    // does this on the first time we exceed the limit; subsequent calls
    // will return null as we drop all input in a broken state.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        // If we're in a broken state, just do nothing.
        //
        // We have to do this check here before we check the buffer, because if
        // we're in a broken state then we'd have already deinited the buffer.
        if (self.state == .broken) return null;

        if (self.buffer.written().len >= self.max_bytes) {
            self.broken();
            return error.OutOfMemory;
        }

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Waiting for a notification so if the byte is not '%' then
            // we're in a broken state. Control mode output should always
            // be wrapped in '%begin/%end' orelse we expect a notification.
            // Return an exit notification.
            .idle => if (byte != '%') {
                self.broken();
                return .{ .exit = {} };
            } else {
                self.buffer.clearRetainingCapacity();
                self.state = .notification;
            },

            // If we're in a notification and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete notification we need to parse.
            .notification => if (byte == '\n') {
                // We have a complete notification, parse it.
                return self.parseNotification() catch {
                    // If parsing failed, then we do not mark the state
                    // as broken because we may be able to continue parsing
                    // other types of notifications.
                    //
                    // In the future we may want to emit a notification
                    // here about unknown or unsupported notifications.
                    return null;
                };
            },

            // If we're in a block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    written,
                    '\n',
                )) |v| v + 1 else 0;
                const line = written[idx..];

                if (parseBlockTerminator(line)) |terminator| {
                    const output = std.mem.trimRight(
                        u8,
                        written[0..idx],
                        "\r\n",
                    );

                    // Important: do not clear buffer since the notification
                    // contains it.
                    self.state = .idle;
                    switch (terminator) {
                        .end => return .{ .block_end = output },
                        .err => {
                            log.warn("tmux control mode error={s}", .{output});
                            return .{ .block_err = output };
                        },
                    }
                }

                // Didn't end the block, continue accumulating.
            },
        }

        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return null;
    }

    const ParseError = error{RegexError};

    const BlockTerminator = enum { end, err };

    /// Block payload is raw data, so a line only terminates a block if it
    /// exactly matches tmux's `%end`/`%error` guard-line shape.
    fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminator {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
            .end
        else if (std.mem.eql(u8, cmd, "%error"))
            .err
        else
            return null;

        const time = fields.next() orelse return null;
        const command_id = fields.next() orelse return null;
        const flags = fields.next() orelse return null;
        const extra = fields.next();

        // In the future, we should compare these to the %begin block
        // because the tmux source guarantees that these always match and
        // that is a more robust way to match.
        _ = std.fmt.parseInt(usize, time, 10) catch return null;
        _ = std.fmt.parseInt(usize, command_id, 10) catch return null;
        _ = std.fmt.parseInt(usize, flags, 10) catch return null;
        if (extra != null) return null;

        return terminator;
    }

    /// Decode tmux's `\ooo` octal escapes in `data` in place, returning the
    /// (possibly shorter) decoded slice. A backslash not followed by exactly
    /// 3 octal digits is passed through literally (defensive; tmux always emits
    /// 3). Decoded length is always <= the source length, so in-place decoding
    /// never overruns the write cursor.
    fn unescapeOutput(data: []u8) []u8 {
        var w: usize = 0;
        var r: usize = 0;
        while (r < data.len) : (w += 1) {
            if (data[r] == '\\' and r + 3 < data.len and
                isOctalLead(data[r + 1]) and isOctal(data[r + 2]) and isOctal(data[r + 3]))
            {
                data[w] = (@as(u8, data[r + 1] - '0') << 6) |
                    (@as(u8, data[r + 2] - '0') << 3) |
                    (data[r + 3] - '0');
                r += 4;
            } else {
                data[w] = data[r];
                r += 1;
            }
        }
        return data[0..w];
    }

    fn isOctal(b: u8) bool {
        return b >= '0' and b <= '7';
    }

    /// The first digit of a `\ooo` escape must be 0-3: anything higher does
    /// not fit in a byte (`\400` == 256). tmux never emits those, and without
    /// this guard the `digit << 6` below overflows u8 and panics.
    fn isOctalLead(b: u8) bool {
        return b >= '0' and b <= '3';
    }

    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const cmd = cmd: {
            const idx = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            break :cmd line[0..idx];
        };

        // The notification MUST exist because we guard entering the notification
        // state on seeing at least a '%'.
        if (std.mem.eql(u8, cmd, "%begin")) {
            // We don't use the rest of the tokens for now because tmux
            // claims to guarantee that begin/end are always in order and
            // never intermixed. In the future, we should probably validate
            // this.
            // TODO(tmuxcc): do this before merge?

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            var re = oni.Regex.init(
                "^%output %([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            // tmux escapes %output data as `\ooo` (backslash + exactly 3 octal
            // digits) for every non-printable byte. Decode in place: `line` is a
            // mutable slice into our own buffer (Allocating.written() -> []u8),
            // and the returned slice is consumed by the caller before the next
            // put() reuses the buffer, so this is safe. Decoded length <= source.
            const raw = line[@intCast(starts[2])..@intCast(ends[2])];
            const data = unescapeOutput(raw);

            // Important: do not clear buffer here since data points to it
            self.state = .idle;
            return .{ .output = .{ .pane_id = id, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-changed \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_changed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%session-window-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-window-changed \\$([0-9]+) @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .session_window_changed = .{
                .session_id = session_id,
                .window_id = window_id,
            } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) cmd: {
            if (!std.mem.eql(u8, line, "%sessions-changed")) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            var re = oni.Regex.init(
                "^%layout-change @([0-9]+) (.+) (.+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const layout = line[@intCast(starts[2])..@intCast(ends[2])];
            const visible_layout = line[@intCast(starts[3])..@intCast(ends[3])];
            const raw_flags = line[@intCast(starts[4])..@intCast(ends[4])];

            // Important: do not clear buffer here since layout strings point to it
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id,
                .layout = layout,
                .visible_layout = visible_layout,
                .raw_flags = raw_flags,
            } };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            var re = oni.Regex.init(
                "^%window-add @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%window-renamed")) cmd: {
            var re = oni.Regex.init(
                "^%window-renamed @([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            var re = oni.Regex.init(
                "^%window-pane-changed @([0-9]+) %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const pane_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = window_id, .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            var re = oni.Regex.init(
                "^%client-detached (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];

            // Important: do not clear buffer here since client points to it
            self.state = .idle;
            return .{ .client_detached = .{ .client = client } };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%client-session-changed (.+) \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];
            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[3])..@intCast(ends[3])];

            // Important: do not clear buffer here since client/name point to it
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client, .session_id = session_id, .name = name } };
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        // Unknown command. Clear the buffer and return to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1). A lot of the simple documentation was copied from that man
/// page here.
pub const Notification = union(enum) {
    /// Entering tmux control mode. This isn't an actual event sent by
    /// tmux but is one sent by us to indicate that we have detected that
    /// tmux control mode is starting.
    enter,

    /// Exit.
    ///
    /// NOTE: The tmux protocol contains a "reason" string (human friendly)
    /// associated with this. We currently drop it because we don't need it
    /// but this may be something we want to add later. If we do add it,
    /// we have to consider buffer limits and how we handle those (dropping
    /// vs truncating, etc.).
    exit,

    /// Dispatched at the end of a begin/end block with the raw data.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: []const u8,
    block_err: []const u8,

    /// Raw output from a pane.
    output: struct {
        pane_id: usize,
        data: []const u8, // unescaped (octal `\ooo` escapes decoded)
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    session_changed: struct {
        id: usize,
        name: []const u8,
    },

    /// The active window in the session with ID session-id changed to the
    /// window with ID window-id.
    session_window_changed: struct {
        session_id: usize,
        window_id: usize,
    },

    /// A session was created or destroyed.
    sessions_changed,

    /// The layout of the window with ID window-id changed.
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },

    /// The window with ID window-id was linked to the current session.
    window_add: struct {
        id: usize,
    },

    /// The window with ID window-id was renamed to name.
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The active pane in the window with ID window-id changed to the pane
    /// with ID pane-id.
    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },

    /// The client has detached.
    client_detached: struct {
        client: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
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

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err);
}

test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end);
}

test "tmux block payload may start with %end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end not really\nhello", n.block_end);
}

test "tmux block payload may start with %error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%error not really\nhello", n.block_end);
}

test "tmux block may terminate with real %error after misleading payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("%error not really\nhello", n.block_err);
}

test "tmux block terminator requires exact token count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1 trailing\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end);
}

test "tmux block terminator requires numeric metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end foo bar baz\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end);
}

test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output decodes octal escapes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // \033[1mhi\033[0m  -> ESC [ 1 m h i ESC [ 0 m
    const line = "%output %0 \\033[1mhi\\033[0m";
    for (line) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(0, n.output.pane_id);
    try testing.expectEqualStrings("\x1b[1mhi\x1b[0m", n.output.data);
}

test "tmux output passes through printable data unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output decodes a literal backslash (134) and trailing data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %1 a\\134b") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("a\\b", n.output.data); // \134 -> backslash byte
}

test "tmux output leaves out-of-range octal escapes literal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // \7xx cannot be a byte escape (\400 == 256 is the first overflow), so
    // it must pass through literally rather than overflow the decode math.
    for ("%output %1 a\\777b") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("a\\777b", n.output.data);
}

test "tmux output decodes the highest valid octal escape" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %1 \\377") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("\xff", n.output.data);
}

test "tmux session-window-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-window-changed $3 @7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(3, n.session_window_changed.session_id);
    try testing.expectEqual(7, n.session_window_changed.window_id);
}

test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}

test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}

test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}

test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}

test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}

test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}

test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}

test "tmux real -CC transcript fixture" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Embed the real captured tmux -CC session fixture.
    // The file is DCS-wrapped: \x1bP1000p<inner bytes>\x1b\
    // The DCS envelope is stripped by src/terminal/dcs.zig before bytes reach
    // this parser, so we feed only the inner bytes here.
    const raw = @embedFile("testdata/leo-agent-attach-CC.bin");

    const open = std.mem.indexOf(u8, raw, "1000p") orelse
        return error.NoDcsOpen;
    const inner_start = open + "1000p".len;
    const st = std.mem.indexOfPos(u8, raw, inner_start, "\x1b\\") orelse raw.len;
    const inner = raw[inner_start..st];

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    var saw_session_changed = false;
    var saw_output_pane25 = false;

    for (inner) |byte| {
        const notif = try c.put(byte) orelse continue;
        switch (notif) {
            .session_changed => |sc| {
                if (sc.id == 25 and std.mem.indexOf(u8, sc.name, "leo-leoterm") != null) { // $25 is the session ID in the captured fixture
                    saw_session_changed = true;
                }
            },
            .output => |out| {
                if (out.pane_id == 25) saw_output_pane25 = true;
            },
            else => {},
        }
    }

    // Parser must not have broken on real input.
    try testing.expect(c.state != .broken);
    // Must have seen session-changed for session $25 named "leo-leoterm".
    try testing.expect(saw_session_changed);
    // Must have seen at least one output notification for pane %25.
    try testing.expect(saw_output_pane25);
    // Note: %exit is not a recognised notification in this parser (it falls
    // through to the unknown-command path and returns null).  The real exit
    // signal in the protocol is a non-'%' byte at idle state.  The fixture
    // ends with "%exit\r\n" followed by the DCS ST which we have already
    // stripped, so no .exit Notification is emitted — this is expected.
}

test "tmux real -CC fixture %output octal decodes to real ESC bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Same DCS-stripping as the fixture test above.
    const raw = @embedFile("testdata/leo-agent-attach-CC.bin");
    const open = std.mem.indexOf(u8, raw, "1000p") orelse
        return error.NoDcsOpen;
    const inner_start = open + "1000p".len;
    const st = std.mem.indexOfPos(u8, raw, inner_start, "\x1b\\") orelse raw.len;
    const inner = raw[inner_start..st];

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    var saw_decoded_esc = false;
    for (inner) |byte| {
        const notif = try c.put(byte) orelse continue;
        switch (notif) {
            .output => |out| {
                // The fixture contains octal-escaped output (e.g. \033, \017).
                // After decoding, the data must NOT contain the literal 4-char
                // escape "\033", and at least one output must carry a real ESC
                // (0x1b) byte — proving the decode fired on real captured data.
                try testing.expect(std.mem.indexOf(u8, out.data, "\\033") == null);
                if (std.mem.indexOfScalar(u8, out.data, 0x1b) != null) {
                    saw_decoded_esc = true;
                }
            },
            else => {},
        }
    }

    try testing.expect(saw_decoded_esc);
}
